//! `acpmux session move --carry-changes`: a chat's uncommitted work goes with it. The move pushes
//! the branch and makes a fresh worktree of it on the target (`run/session_move.rs`); this adds
//! what the branch lacks, so the agent finds its folder there as it left it here.
//!
//! - [`snapshot`] reads the working tree against HEAD on the source: tracked changes, deletions
//!   and untracked files that are not ignored, as one binary patch. It goes through a copy of
//!   the index, so the person's index, working tree and refs never change (the seed's way,
//!   cmux-tui `link/seed/plan.rs`). Untracked files that likely hold secrets stay behind, by
//!   the same rule a Cloud seed uses (`cmux_git::secrets`), and so do nested repositories.
//! - [`APPLY_SCRIPT`] applies it on the target in the new worktree, only when that worktree is at
//!   the commit the patch was read against. `git apply` is all or nothing: a patch that does not
//!   apply fails the move, which gives the chat back here with its folder unchanged.
//!
//! Every step is a fixed script of git and base64, run on the machine the folder is on (this
//! one, or over ssh for a move `--from` another), its values on stdin, never in the script. So
//! only the machine that drives the move needs an acpmux that knows `--carry-changes`: a cloud
//! VM or a mini on an older build still gives up its changes and takes them. On another machine
//! a registry file (`.npmrc`, `.pypirc`) is not read for a token, so it stays there.
//!
//! The changes land unstaged on the target (what was staged here is not told apart), and the
//! source keeps its own copy: the chat never runs here again, so nothing writes it.

use crate::cli::hosts::RemoteOut;
use anyhow::{Context as _, Result, anyhow, bail};
use base64::Engine as _;
use serde_json::{Value, json};
use std::path::Path;

/// Runs one of the fixed scripts where the folder is, its stdin given.
pub(crate) type Exec<'a> = &'a dyn Fn(&str, &[u8]) -> Result<RemoteOut>;

/// A checkout's uncommitted work, read against `base` (its HEAD).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Carry {
    pub base: String,
    /// `git diff --binary` from `base` to the working tree; empty when nothing is carried.
    pub patch: Vec<u8>,
    /// The files the patch changes, adds or deletes.
    pub files: usize,
    /// Untracked files that stay on the source, each with why.
    pub left_out: Vec<(String, String)>,
}

impl Carry {
    /// What the move records about it (`movedTo.uncommittedCarried`).
    pub fn record(&self) -> Value {
        let left: Vec<Value> =
            self.left_out.iter().map(|(p, why)| json!({"path": p, "why": why})).collect();
        json!({"files": self.files, "bytes": self.patch.len(), "leftOut": left})
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

/// The fixed script that makes the patch: the top folder, the base commit and the untracked files
/// to add (NUL-separated, base64) on three lines of stdin. Prints the number of files the patch
/// touches, its size, then the whole patch in base64, whatever its size: a move never leaves work
/// behind for being large. Exit 4: HEAD is no longer the base.
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
if [ -f "$real" ]; then cp -- "$real" "$s/index" || exit 2
elif [ "$(git config --type=bool core.sparseCheckout)" = true ]; then
  echo "it is a sparse checkout with no index: rebuild it there with git reset -q && git sparse-checkout reapply (edits stay), then move again" >&2; exit 5
else git read-tree HEAD || exit 3; fi
# Every path is a file name, never pathspec magic: `:(glob)**` must not add the secrets left out.
GIT_LITERAL_PATHSPECS=1; export GIT_LITERAL_PATHSPECS
g() { git -c core.fsmonitor=false -c core.quotepath=false "$@"; }
# `--sparse`: a sparse checkout's changes inside its cone carry like any other.
g add --sparse --update -- . || exit 3
if [ -n "$keep" ]; then
  printf '%s' "$keep" | { base64 -d 2>/dev/null || base64 -D; } >"$s/keep" || exit 2
  g add --sparse --pathspec-from-file="$s/keep" --pathspec-file-nul -- || exit 3
fi
tree=$(g write-tree) || exit 3
g diff --name-only -z --no-renames "$base" "$tree" >"$s/names" || exit 3
tr -cd '\000' <"$s/names" | wc -c | tr -d ' '
g diff --binary --full-index --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$base" "$tree" >"$s/patch" || exit 3
size=$(wc -c <"$s/patch" | tr -d ' ')
echo "$size"
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
    let mut number = || lines.next().and_then(|l| l.trim().parse::<usize>().ok());
    let (Some(files), Some(size)) = (number(), number()) else {
        bail!("reading the uncommitted changes answered no counts");
    };
    let patch = decode(lines.next().unwrap_or_default()).context("the patch")?;
    if patch.len() != size {
        bail!("the uncommitted changes came over cut short ({} of {size} bytes)", patch.len());
    }
    Ok(Carry { base, patch, files, left_out })
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

/// The fixed script that applies a carried patch in the chat's new folder on the target: the
/// folder and the base commit on the first two lines of stdin, the patch after them. Exit 4:
/// the worktree there is not at the base.
pub(crate) const APPLY_SCRIPT: &str = r#"read -r d || exit 2; read -r base || exit 2
top=$(git -C "$d" rev-parse --show-toplevel) || exit 2
head=$(git -C "$top" rev-parse HEAD) || exit 2
if [ "$head" != "$base" ]; then echo "the new worktree is at $head, not $base" >&2; exit 4; fi
git -c core.fsmonitor=false -C "$top" apply --binary --whitespace=nowarn -"#;

/// [`APPLY_SCRIPT`]'s stdin for `carry` in `folder`.
pub(crate) fn apply_input(folder: &str, carry: &Carry) -> Vec<u8> {
    let mut input = format!("{folder}\n{}\n", carry.base).into_bytes();
    input.extend_from_slice(&carry.patch);
    input
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
