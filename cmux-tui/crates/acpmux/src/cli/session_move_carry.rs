//! `acpmux session move --carry-changes`: a chat's uncommitted work goes with it. The move pushes
//! the branch and makes a fresh worktree of it on the target (`run/session_move.rs`); this adds
//! what the branch lacks, so the agent finds its folder there as it left it here.
//!
//! - [`snapshot`] reads the index and final working tree independently against HEAD:
//!   tracked changes, deletions and untracked files that are not ignored are carried as binary
//!   patches while staged and unstaged changes stay distinct. It goes through a copy of the index,
//!   so the person's index, working tree and refs never change (the seed's way,
//!   cmux-tui `link/seed/plan.rs`). Untracked files that likely hold secrets stay behind, by
//!   the same rule a Cloud seed uses (`cmux_git::secrets`), and so do nested repositories.
//! - [`APPLY_SCRIPT`] applies it on the target in the new worktree, only when that worktree is at
//!   the commit the patch was read against. a failed apply restores the affected target files from a snapshot and fails the move,
//!   which gives the chat back here with its folder unchanged. If restoration itself fails,
//!   the original files remain in a private recovery archive named in the error.
//!
//! Every step is a fixed script of git and base64, run on the machine the folder is on (this
//! one, or over ssh for a move `--from` another), its values on stdin, never in the script. So
//! only the machine that drives the move needs an acpmux that knows `--carry-changes`: a cloud
//! VM or a mini on an older build still gives up its changes and takes them. On another machine
//! a registry file (`.npmrc`, `.pypirc`) is not read for a token, so it stays there.
//!
//! The target receives the index snapshot and final working tree snapshot separately;
//! the source keeps its own copy: the chat never runs here again, so nothing writes it.

use crate::cli::hosts::RemoteOut;
use anyhow::{Context as _, Result, anyhow, bail};
use base64::Engine as _;
use serde_json::{Value, json};
use std::{collections::BTreeSet, path::Path};

/// Runs one of the fixed scripts where the folder is, its stdin given.
pub(crate) type Exec<'a> = &'a dyn Fn(&str, &[u8]) -> Result<RemoteOut>;

/// A checkout's uncommitted work, read against `base` (its HEAD).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Carry {
    pub base: String,
    /// `git diff --binary` from `base` to the working tree; empty when the final worktree matches `base`.
    pub patch: Vec<u8>,
    /// `git diff --cached --binary` from `base` to the source index.
    pub staged_patch: Vec<u8>,
    /// NUL-separated paths whose source index entry has the intent-to-add flag.
    pub intent_to_add: Vec<u8>,
    /// A tar of empty files (or safe symlink placeholders) with the intent entries' modes.
    pub intent_placeholders: Vec<u8>,
    /// NUL-separated affected paths, including both sides of renames.
    pub affected_paths: Vec<u8>,
    /// Affected paths and their ancestors, deepest first, for filesystem recovery.
    pub recovery_paths: Vec<u8>,
    /// The files either snapshot changes, adds or deletes.
    pub files: usize,
    /// Untracked files that stay on the source, each with why.
    pub left_out: Vec<(String, String)>,
}

impl Carry {
    /// What the move records about it (`movedTo.uncommittedCarried`).
    pub fn record(&self) -> Value {
        let left: Vec<Value> =
            self.left_out.iter().map(|(p, why)| json!({"path": p, "why": why})).collect();
        json!({"files": self.files, "bytes": self.staged_patch.len() + self.patch.len() + self.intent_to_add.len() + self.intent_placeholders.len() + self.affected_paths.len() + self.recovery_paths.len(), "leftOut": left})
    }
}

/// The fixed script that lists what a carry could take: the checkout's top folder on stdin;
/// prints its HEAD, then the untracked files that are not ignored (NUL-separated, base64).
const LIST_SCRIPT: &str = r#"read -r top || exit 2
cd -- "$top" || exit 2
git rev-parse HEAD || exit 3
s=$(mktemp) || exit 2
trap 'rm -f -- "$s"' EXIT
git -c core.fsmonitor=false ls-files -z --others --exclude-standard >"$s" || exit 3
base64 <"$s" | tr -d '\n'
echo"#;

/// The fixed script that makes the patches: the top folder, the base commit and the untracked
/// files to add (NUL-separated, base64) on three lines of stdin. Prints the changed paths
/// (NUL-separated, base64), index entries with flags, staged and final patch sizes,
/// then both patches in base64, whatever
/// their size: a move never leaves work behind for being large. Exit 4: HEAD is no longer the
/// base.
const PATCH_SCRIPT: &str = r#"read -r top || exit 2; read -r base || exit 2; read -r keep
cd -- "$top" || exit 2
head=$(git rev-parse HEAD) || exit 3
if [ "$head" != "$base" ]; then echo "HEAD moved from $base to $head" >&2; exit 4; fi
real=$(git rev-parse --git-path index) || exit 3
s=$(mktemp -d) || exit 2
trap 'rm -rf -- "$s"' EXIT
GIT_INDEX_FILE="$s/index"; export GIT_INDEX_FILE
# With no index, the scratch one starts at HEAD: an empty one would carry every tracked file
# the untracked list leaves out (a tracked `.env`) as a deletion. A sparse checkout's
# skip-worktree marks live only in its index, so without one every file outside the cone would
# read as deleted: that is refused (exit 5).
# The copy keeps the index's time, and nothing else of it (a flag or an ACL that forbids writing
# would stop the scratch index too). Git reads a file as old as its index again instead of
# trusting its size and time, and a copy with a newer time would pass a same-size edit by.
if [ -f "$real" ]; then { cp -- "$real" "$s/index" && touch -r "$real" "$s/index"; } || exit 2
elif [ "$(git config --type=bool core.sparseCheckout)" = true ]; then
  echo "it is a sparse checkout with no index: rebuild it there with git reset -q && git sparse-checkout reapply (edits stay), then move again" >&2; exit 5
else git read-tree HEAD || exit 3; fi
# Every path is a file name, never pathspec magic: `:(glob)**` must not add the secrets left out.
GIT_LITERAL_PATHSPECS=1; export GIT_LITERAL_PATHSPECS
g() { git -c core.fsmonitor=false -c core.quotepath=false "$@"; }
g ls-files --unmerged >"$s/unmerged" || exit 3
if [ -s "$s/unmerged" ]; then
  echo "the index has unresolved conflicts: resolve and stage them, then move again" >&2; exit 5
fi
# A gitlink patch updates only the superproject index, not a submodule checkout.
# Refuse unstaged submodule changes rather than report a move that drops them.
g diff --raw --ignore-submodules=none --no-renames >"$s/unstaged-raw" || exit 3
if LC_ALL=C grep -q '^:160000 ' "$s/unstaged-raw"; then
  echo "unstaged submodule changes cannot be carried: preserve them in the submodule and stage its commit before moving" >&2; exit 5
fi
g diff --submodule=short --ignore-submodules=none --cached --binary --no-renames --ita-visible-in-index --full-index --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$base" >"$s/staged" || exit 3
g diff --submodule=short --ignore-submodules=none --cached --name-only -z --no-renames --ita-visible-in-index "$base" >"$s/names" || exit 3
# The two index views together include every intent entry, including an empty
# tracked file replaced by intent. Send debug records only for changed candidates,
# not stat metadata for every unchanged tracked file in a large checkout.
g diff --submodule=short --ignore-submodules=none --cached --name-only -z --no-renames --ita-invisible-in-index "$base" >"$s/intent-candidates" || exit 3
cat "$s/names" >>"$s/intent-candidates" || exit 2
: >"$s/index-entries"
if [ -s "$s/intent-candidates" ]; then
  xargs -0 git -c core.fsmonitor=false ls-files --stage --debug -z -- <"$s/intent-candidates" >"$s/index-entries" || exit 3
fi
# `--sparse`: a sparse checkout's changes inside its cone carry like any other.
g add --sparse --update -- . || exit 3
if [ -n "$keep" ]; then
  printf '%s' "$keep" | { base64 -d 2>/dev/null || base64 -D; } >"$s/keep" || exit 2
  g add --sparse --pathspec-from-file="$s/keep" --pathspec-file-nul -- || exit 3
fi
tree=$(g write-tree) || exit 3
g diff --submodule=short --ignore-submodules=none --name-only -z --no-renames "$base" "$tree" >>"$s/names" || exit 3
base64 <"$s/names" | tr -d '\n'
echo
base64 <"$s/index-entries" | tr -d '\n'
echo
wc -c <"$s/staged" | tr -d ' '
g diff --submodule=short --ignore-submodules=none --binary --no-renames --full-index --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$base" "$tree" >"$s/patch" || exit 3
size=$(wc -c <"$s/patch" | tr -d ' ')
echo "$size"
base64 <"$s/staged" | tr -d '\n'
echo
base64 <"$s/patch" | tr -d '\n'
echo"#;

fn decode(text: &str) -> Result<Vec<u8>> {
    let text: String = text.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    Ok(base64::engine::general_purpose::STANDARD.decode(text)?)
}

fn failed(out: &RemoteOut, what: &str) -> anyhow::Error {
    let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
    anyhow!("{what} failed: {last}")
}

/// The uncommitted work of the checkout at `top`, read where it is through `exec`. `local`: the
/// checkout is on this machine, so a registry file is read for a token; on another machine it
/// stays behind unread. The repository gains only unreferenced objects, as `git stash create`
/// leaves; nothing the person sees changes.
pub(crate) fn snapshot(exec: Exec<'_>, top: &Path, local: bool) -> Result<Carry> {
    let top_line = top.to_string_lossy();
    if top_line.contains('\n') {
        bail!("the checkout folder's name has a line break");
    }
    let out = exec(LIST_SCRIPT, format!("{top_line}\n").as_bytes())?;
    if !out.ok {
        return Err(failed(&out, "listing the uncommitted changes"));
    }
    let mut lines = out.stdout.lines();
    let base = lines.next().unwrap_or_default().trim().to_owned();
    if base.len() < 40 || !base.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("the checkout answered no HEAD commit");
    }
    let untracked = decode(lines.next().unwrap_or_default()).context("the untracked list")?;
    // A registry file elsewhere is read in a folder that has none, so it counts as a secret.
    let unread = tempfile::tempdir().context("a scratch folder")?;
    let read_in = if local { top } else { unread.path() };
    let (mut keep, mut left_out) = (Vec::new(), Vec::new());
    for path in untracked.split(|b| *b == 0).filter(|p| !p.is_empty()) {
        let why = if path.ends_with(b"/") {
            Some("a nested git repository")
        } else {
            leave_out(read_in, path)
        };
        match why {
            Some(why) => left_out.push((String::from_utf8_lossy(path).into_owned(), why.into())),
            None => {
                keep.extend_from_slice(path);
                keep.push(0);
            }
        }
    }
    let keep = base64::engine::general_purpose::STANDARD.encode(&keep);
    let input = format!("{top_line}\n{base}\n{keep}\n");
    let out = exec(PATCH_SCRIPT, input.as_bytes())?;
    if !out.ok {
        return Err(failed(&out, "reading the uncommitted changes"));
    }
    let mut lines = out.stdout.lines();
    let names = decode(lines.next().unwrap_or_default()).context("the changed paths")?;
    let index_entries = decode(lines.next().unwrap_or_default()).context("the index entries")?;
    let (intent_to_add, intent_placeholders) = intent_payload(&index_entries)?;
    let paths = names
        .split(|b| *b == 0)
        .chain(intent_to_add.split(|b| *b == 0))
        .filter(|p| !p.is_empty())
        .collect::<BTreeSet<_>>();
    let files = paths.len();
    let mut recovery = paths.clone();
    for path in &paths {
        for (offset, byte) in path.iter().enumerate() {
            if *byte == b'/' {
                recovery.insert(&path[..offset]);
            }
        }
    }
    let recovery_paths =
        recovery.into_iter().rev().flat_map(|p| p.iter().copied().chain([0])).collect();
    // Descendants precede their parent when rollback removes newly created paths.
    let affected_paths =
        paths.into_iter().rev().flat_map(|p| p.iter().copied().chain([0])).collect();
    let mut number = || lines.next().and_then(|l| l.trim().parse::<usize>().ok());
    let (Some(staged_size), Some(size)) = (number(), number()) else {
        bail!("reading the uncommitted changes answered no counts");
    };
    let staged_patch = decode(lines.next().unwrap_or_default()).context("the staged patch")?;
    if staged_patch.len() != staged_size {
        bail!(
            "the staged changes came over cut short ({} of {staged_size} bytes)",
            staged_patch.len()
        );
    }
    let patch = decode(lines.next().unwrap_or_default()).context("the patch")?;
    if patch.len() != size {
        bail!("the uncommitted changes came over cut short ({} of {size} bytes)", patch.len());
    }
    Ok(Carry {
        base,
        patch,
        staged_patch,
        intent_to_add,
        intent_placeholders,
        affected_paths,
        recovery_paths,
        files,
        left_out,
    })
}

/// Git's debug record is a NUL-terminated stage/path header followed by five stat lines.
/// Read the actual CE_INTENT_TO_ADD bit (1 << 29), not a diff heuristic: an intent entry
/// may replace a path in HEAD, even one whose empty blob is unchanged. Unknown formats
/// refuse rather than silently losing index flags. Paths remain raw bytes throughout.
fn intent_payload(mut data: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut paths = Vec::new();
    let mut seen = BTreeSet::new();
    let mut archive = tar::Builder::new(Vec::new());
    while !data.is_empty() {
        let nul = data.iter().position(|b| *b == 0).context("unterminated index entry")?;
        let entry = &data[..nul];
        data = &data[nul + 1..];
        let tab = entry.iter().position(|b| *b == b'\t').context("index entry without a path")?;
        let path = &entry[tab + 1..];
        let metadata = std::str::from_utf8(&entry[..tab])?;
        let mut metadata = metadata.split_whitespace();
        let mode = u32::from_str_radix(metadata.next().context("index entry without a mode")?, 8)?;
        let mut flags = 0;
        for prefix in ["  ctime:", "  mtime:", "  dev:", "  uid:", "  size:"] {
            let end = data.iter().position(|b| *b == b'\n').context("truncated index flags")?;
            let line = std::str::from_utf8(&data[..end])?;
            if !line.starts_with(prefix) {
                bail!("unrecognized Git index debug format: cannot preserve intent-to-add");
            }
            if prefix == "  size:" {
                let (_, value) = line.split_once("flags:").context("missing index flags")?;
                flags = u32::from_str_radix(value.trim(), 16)?;
            }
            data = &data[end + 1..];
        }
        if flags & (1 << 29) == 0 || !seen.insert(path.to_vec()) {
            continue;
        }
        let mut header = tar::Header::new_gnu();
        header.set_size(0);
        match mode {
            0o100644 | 0o100755 => header.set_mode(mode & 0o777),
            0o120000 => {
                header.set_entry_type(tar::EntryType::Symlink);
                header.set_mode(0o777);
                // The index stores an empty blob for a symlink's intent, which cannot be
                // checked out as a symlink. Its actual target comes from the worktree patch.
                header.set_link_name(".")?;
            }
            _ => bail!("unsupported intent-to-add mode {mode:o}"),
        }
        #[cfg(unix)]
        let name = {
            use std::os::unix::ffi::OsStrExt as _;
            Path::new(std::ffi::OsStr::from_bytes(path))
        };
        #[cfg(not(unix))]
        let name = Path::new(std::str::from_utf8(path)?);
        header.set_cksum();
        archive.append_data(&mut header, name, std::io::empty())?;
        paths.extend_from_slice(path);
        paths.push(0);
    }
    let placeholders = if paths.is_empty() { Vec::new() } else { archive.into_inner()? };
    Ok((paths, placeholders))
}

/// Why an untracked file stays behind (`cmux_git::secrets`), or None when it goes.
#[cfg(unix)]
fn leave_out(top: &Path, relative: &[u8]) -> Option<&'static str> {
    cmux_git::secrets::reason(top, relative)
}

/// The secrets rule reads git's raw path bytes, which only unix has: elsewhere no untracked file
/// is carried.
#[cfg(not(unix))]
fn leave_out(_top: &Path, _relative: &[u8]) -> Option<&'static str> {
    Some("untracked files are carried only from macOS and Linux")
}

/// The target folder and base commit are plain lines, followed by a tar stream containing
/// only `staged`, `patch`, `intent`, `intent-placeholders`, `paths` and `recovery-paths`. The candidate index is prepared under the target's
/// index lock and published only after the worktree apply succeeds. Exit 4: different HEAD.
pub(crate) const APPLY_SCRIPT: &str = r#"read -r d || exit 2; read -r base || exit 2
top=$(git -C "$d" rev-parse --show-toplevel) || exit 2
head=$(git -C "$top" rev-parse HEAD) || exit 2
if [ "$head" != "$base" ]; then echo "the new worktree is at $head, not $base" >&2; exit 4; fi
s=$(mktemp -d) || exit 2
keep_backup=0
cleanup() { if [ "$keep_backup" = 0 ]; then rm -rf -- "$s"; fi; }
trap cleanup EXIT
# Do not read multi-megabyte payloads into shell variables: tar consumes stdin directly.
tar -xf - -C "$s" staged patch intent intent-placeholders paths recovery-paths || exit 2
# Recovery must never follow a symlink created by the failed apply into files
# outside the carry. Descendants are skipped; their recorded ancestor is handled
# separately. Use the same guard while taking the backup.
cat >"$s/path-guards.sh" <<'GUARDS'
safe_parents() {
  parent=$1
  while [ "$parent" != "${parent%/*}" ]; do
    parent=${parent%/*}
    [ ! -L "$parent" ] || return 1
  done
}
matches_expected() {
  oid=$(GIT_INDEX_FILE="$s/expected" git rev-parse --verify ":$1" 2>/dev/null) || return 1
  entry=$(GIT_INDEX_FILE="$s/expected" git ls-files --stage -- "$1") || return 1
  mode=${entry%% *}
  git cat-file blob "$oid" >"$s/compare-blob" 2>/dev/null || return 1
  if [ -L "$1" ]; then
    [ "$mode" = 120000 ] &&
      [ "$(readlink -- "$1"; printf .)" = "$(cat "$s/compare-blob"; printf '\n.')" ]
  else
    case "$mode" in
      100644) [ ! -x "$1" ] || return 1;;
      100755) [ -x "$1" ] || return 1;;
      *) return 1;;
    esac
    [ -f "$1" ] && cmp -s -- "$s/compare-blob" "$1"
  fi
}
matches_before() {
  parent=$1
  while [ "$parent" != "${parent%/*}" ]; do
    parent=${parent%/*}
    [ ! -L "$s/before/$parent" ] || return 1
  done
  if [ -L "$1" ]; then
    [ -L "$s/before/$1" ] &&
      [ "$(readlink -- "$1"; printf .)" = "$(readlink -- "$s/before/$1"; printf .)" ]
  else
    [ ! -L "$s/before/$1" ] && [ -f "$s/before/$1" ] &&
      cmp -s -- "$s/before/$1" "$1"
  fi
}
GUARDS
cd -- "$top" || exit 2
real=$(git rev-parse --git-path index) || exit 3
# Claim only our own lock. A concurrent Git writer makes the carry refuse unchanged.
if ! (set -C; : >"$real.lock") 2>/dev/null; then
  echo "the target index is locked: finish its Git operation, then move again" >&2; exit 5
fi
trap 'rm -f -- "$real.lock"; cleanup' EXIT
# A checkout can finish while the payload is arriving. Validate under our lock.
head=$(git rev-parse HEAD) || exit 3
if [ "$head" != "$base" ]; then echo "the new worktree is at $head, not $base" >&2; exit 4; fi
GIT_INDEX_FILE="$s/index"; export GIT_INDEX_FILE
GIT_LITERAL_PATHSPECS=1; export GIT_LITERAL_PATHSPECS
if [ -f "$real" ]; then cp -- "$real" "$s/index" || exit 2
else git read-tree "$base" || exit 3; fi
if [ -s "$s/paths" ]; then
  # An intent flag can change without either patch changing. Never overwrite an
  # edit saved only in the target index, even when no patch would detect it.
  # Include rename sources: Git can otherwise move their newer staged content.
  # A committed empty file replaced by intent matches the visible blob but
  # differs in the invisible view. Either difference protects target staging.
  for view in --ita-visible-in-index --ita-invisible-in-index; do
    if ! xargs -0 git -c core.fsmonitor=false diff --cached --quiet --no-ext-diff --no-textconv --ignore-submodules=none "$view" "$base" -- <"$s/paths"; then
      echo "the target index changed at a carried path: preserve its staging before moving again" >&2; exit 5
    fi
  done
fi
if [ -s "$s/patch" ]; then
  git -c core.fsmonitor=false -c core.symlinks=true -C "$top" apply --binary --whitespace=nowarn --check "$s/patch" || exit 5
  # A separate expected worktree index identifies complete files created by the
  # carry. An absent path can also be created by somebody else during the apply.
  GIT_INDEX_FILE="$s/expected" git read-tree "$base" || exit 5
  GIT_INDEX_FILE="$s/expected" git apply --cached --binary --whitespace=nowarn "$s/patch" || exit 5
fi
if [ -s "$s/staged" ]; then
  git -c core.fsmonitor=false -c core.symlinks=true -C "$top" apply --binary --whitespace=nowarn --cached "$s/staged" || exit 5
fi
if [ -s "$s/intent" ]; then
  # Recreate flags against a scratch worktree with the original modes. The safe
  # placeholders also support deleted worktree paths and intent-to-add symlinks.
  # Restore source modes regardless of target filemode/symlink or sparse settings.
  mkdir "$s/intent-worktree" || exit 2
  tar -xf "$s/intent-placeholders" -C "$s/intent-worktree" || exit 5
  git update-index --force-remove -z --stdin <"$s/intent" || exit 5
  git -c core.fsmonitor=false -c core.filemode=true -c core.symlinks=true --work-tree="$s/intent-worktree" add --sparse -N -f --pathspec-from-file="$s/intent" --pathspec-file-nul -- || exit 5
fi
# Applying a gitlink does not check out an initialized submodule. Refuse a
# mismatched checkout before writes, preserving its own worktree and refs.
if [ -s "$s/paths" ]; then
  xargs -0 sh -c 'for p do
    [ -e "$p/.git" ] || continue
    entry=$(git ls-files --stage -- "$p") || exit 1
    [ "${entry%% *}" = 160000 ] || continue
    want=$(git rev-parse --verify ":$p") || exit 1
    actual=$(unset GIT_INDEX_FILE; git -C "$p" rev-parse HEAD) || exit 1
    if [ "$want" != "$actual" ]; then
      printf "initialized target submodule needs commit %s before carry: %s\n" "$want" "$p" >&2
      exit 1
    fi
  done' sh <"$s/paths" || exit 5
fi
# Write the candidate beside the real index before touching the working tree. Publishing
# is then a rename on the same filesystem, with no allocation after the worktree changes.
cp -- "$s/index" "$real.lock" || exit 2
retain_recovery() {
  keep_backup=1
  echo "worktree recovery needs attention: original files are in $s/worktree-before.tar; originally absent paths are in $s/absent (NUL-separated)" >&2
}
restore_worktree() {
  # A failed Git write and a concurrent save can produce the same partial state.
  # Compare raw bytes, not filtered Git diffs. Any ambiguous file leaves the whole
  # worktree untouched and the original archive available for explicit recovery.
  mkdir "$s/before" || { retain_recovery; return 1; }
  tar --xattrs --acls -xpf "$s/worktree-before.tar" -C "$s/before" || { retain_recovery; return 1; }
  if ! xargs -0 sh -c 's=$1; . "$s/path-guards.sh"; shift; failed=0; for p do
    safe_parents "$p" || continue
    if [ -L "$p" ] || [ -f "$p" ]; then
      if ! matches_before "$p" && ! matches_expected "$p"; then
        printf "preserving ambiguous target path: %s\n" "$p" >&2
        failed=1
      fi
    fi
  done; exit "$failed"' sh "$s" <"$s/recovery-paths"; then
    retain_recovery
    return 1
  fi
  # Extract only originals that need restoring. Replacing an untouched inode
  # would discard metadata that Git never touched (and race with annotations).
  : >"$s/restore"
  xargs -0 sh -c 's=$1; . "$s/path-guards.sh"; shift; for p do
    if ! safe_parents "$p" || ! matches_before "$p" ||
      { [ -x "$p" ] && [ ! -x "$s/before/$p" ]; } ||
      { [ ! -x "$p" ] && [ -x "$s/before/$p" ]; }; then
      printf "%s\000" "$p" >>"$s/restore"
    fi
  done' sh "$s" <"$s/present" || { retain_recovery; return 1; }
  cat "$s/directories" >>"$s/restore" || { retain_recovery; return 1; }
  restored=0
  # A carried file may replace a directory. Remove that file before restoring
  # the directory's original children; never remove an existing directory tree.
  if [ -s "$s/directories" ]; then
    xargs -0 sh -c '. "$1/path-guards.sh"; shift; for p do
      safe_parents "$p" || continue
      if [ -L "$p" ] || [ -f "$p" ]; then rm -f -- "$p" || exit 1; fi
    done' sh "$s" <"$s/directories" || restored=1
    # Remove every replacement first: a parent file would otherwise prevent
    # mkdir from restoring a deeper original directory. mkdir creates parents.
    xargs -0 sh -c '. "$1/path-guards.sh"; shift; for p do
      safe_parents "$p" || continue
      mkdir -p -- "$p" || exit 1
    done' sh "$s" <"$s/directories" || restored=1
  fi
  if [ -s "$s/absent" ]; then
    xargs -0 sh -c 's=$1; . "$s/path-guards.sh"; shift; failed=0; for p do
      safe_parents "$p" || continue
      if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir -- "$p" || failed=1
      elif [ -e "$p" ] || [ -L "$p" ]; then
        if matches_expected "$p"; then
          rm -f -- "$p" || failed=1
        else
          printf "preserving ambiguous target path: %s\n" "$p" >&2
          failed=1
        fi
      fi
    done; exit "$failed"' sh "$s" <"$s/absent" || restored=1
  fi
  if [ -s "$s/present" ]; then
    # A file may have become an empty directory while a later patch failed.
    xargs -0 sh -c '. "$1/path-guards.sh"; shift; for p do
      safe_parents "$p" || continue
      if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir -- "$p" || exit 1; fi
    done' sh "$s" <"$s/present" || restored=1
  fi
  # Every original file must now have real directory ancestors. If a symlink
  # still blocks one, keep the archive instead of extracting through it.
  if xargs -0 sh -c '. "$1/path-guards.sh"; shift; for p do
    safe_parents "$p" || exit 1
  done' sh "$s" <"$s/present"; then
    if [ -s "$s/restore" ]; then
      tar --xattrs --acls --no-recursion -xpf "$s/worktree-before.tar" -C "$top" --null -T "$s/restore" || restored=1
    fi
  else restored=1; fi
  if [ "$restored" != 0 ]; then
    retain_recovery
    return 1
  fi
}
if [ -s "$s/patch" ]; then
  # --check cannot predict disk exhaustion or a write error. Snapshot exactly the
  # affected worktree files before the first write; never recurse into submodules.
  : >"$s/present"; : >"$s/absent"; : >"$s/directories"
  xargs -0 sh -c 's=$1; . "$s/path-guards.sh"; shift; for p do
    safe_parents "$p" || continue
    if [ -L "$p" ] || [ -f "$p" ]; then printf "%s\000" "$p" >>"$s/present"
    elif [ ! -e "$p" ]; then printf "%s\000" "$p" >>"$s/absent"
    elif [ -d "$p" ]; then printf "%s\000" "$p" >>"$s/directories"
    else exit 1; fi
  done' sh "$s" <"$s/recovery-paths" || exit 5
  # Directory headers preserve permissions without traversing their contents.
  tar --xattrs --acls -cpf "$s/worktree-before.tar" --no-recursion --null -T "$s/present" -T "$s/directories" || exit 5
  if ! git -c core.fsmonitor=false -c core.symlinks=true -C "$top" apply --binary --whitespace=nowarn "$s/patch"; then
    restore_worktree || exit 6
    exit 5
  fi
  # Git can warn about a failed unlink yet exit successfully. Verify the final
  # worktree before publishing staging; in particular, every deletion must hold.
  if ! git -c core.fsmonitor=false -c core.symlinks=true -C "$top" apply --reverse --check --binary --whitespace=nowarn "$s/patch"; then
    restore_worktree || exit 6
    exit 5
  fi
fi
# Once published, another writer may immediately claim index.lock; never clean up its lock.
trap cleanup EXIT
if ! mv -- "$real.lock" "$real"; then
  rm -f -- "$real.lock"
  if [ -s "$s/patch" ]; then
    restore_worktree || exit 6
  fi
  exit 5
fi"#;

/// [`APPLY_SCRIPT`]'s stdin for `carry` in `folder`, framed without shell-sized variables.
pub(crate) fn apply_input(folder: &str, carry: &Carry) -> Result<Vec<u8>> {
    let mut input = format!("{folder}\n{}\n", carry.base).into_bytes();
    {
        let mut archive = tar::Builder::new(&mut input);
        for (name, bytes) in [
            ("staged", carry.staged_patch.as_slice()),
            ("patch", carry.patch.as_slice()),
            ("intent", carry.intent_to_add.as_slice()),
            ("intent-placeholders", carry.intent_placeholders.as_slice()),
            ("paths", carry.affected_paths.as_slice()),
            ("recovery-paths", carry.recovery_paths.as_slice()),
        ] {
            let mut header = tar::Header::new_ustar();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o600);
            header.set_cksum();
            archive.append_data(&mut header, name, bytes)?;
        }
        archive.finish()?;
    }
    Ok(input)
}

/// The base a carry was read against must be the commit the move pushed: one that moved on
/// between the two would apply the patch to the wrong tree.
pub(crate) fn check_base(carry: &Carry, pushed: &str) -> Result<()> {
    if carry.base != pushed {
        return Err(anyhow!(
            "the checkout moved from {pushed} to {} while it was read: move it again",
            carry.base
        ));
    }
    Ok(())
}

#[cfg(all(test, unix))]
#[path = "session_move_carry_tests.rs"]
mod tests;
