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
//! - A source on another machine (`--from`) reads it there with the hidden `acpmux carry-out`,
//!   which prints [`Carry::to_wire`].
//!
//! The changes land unstaged on the target (what was staged here is not told apart), and the
//! source keeps its own copy: the chat never runs here again, so nothing writes it.

use anyhow::{Context as _, Result, anyhow, bail};
use base64::Engine as _;
use serde_json::{Value, json};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The most a carried patch may be: more is work to commit and push, not to carry.
pub(crate) const MAX_CARRY_BYTES: usize = 64 * 1024 * 1024;

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

    /// `acpmux carry-out`'s answer: one JSON line, then the patch in base64 on one line.
    pub fn to_wire(&self) -> String {
        let mut head = self.record();
        head["base"] = json!(self.base);
        let patch = base64::engine::general_purpose::STANDARD.encode(&self.patch);
        format!("{head}\n{patch}\n")
    }

    /// [`Carry::to_wire`] read back.
    pub fn from_wire(text: &str) -> Result<Self> {
        let mut lines = text.lines();
        let head: Value = serde_json::from_str(lines.next().unwrap_or_default())
            .context("the source's carry-out answered no summary line")?;
        let base = head.get("base").and_then(Value::as_str).unwrap_or_default().to_owned();
        if base.len() < 40 || !base.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("the source's carry-out named no base commit");
        }
        let patch = base64::engine::general_purpose::STANDARD
            .decode(lines.next().unwrap_or_default().trim())
            .context("the source's carry-out patch is not base64")?;
        let files = head.get("files").and_then(Value::as_u64).unwrap_or(0) as usize;
        let left_out = head
            .get("leftOut")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|l| {
                let path = l.get("path")?.as_str()?.to_owned();
                Some((path, l.get("why").and_then(Value::as_str).unwrap_or_default().to_owned()))
            })
            .collect();
        Ok(Self { base, patch, files, left_out })
    }
}

/// `git` in `top` (with the scratch index `index`, when named), `stdin` on its stdin; its
/// stdout, or the error with git's last stderr line.
fn git(top: &Path, index: Option<&Path>, args: &[&str], stdin: Option<&[u8]>) -> Result<Vec<u8>> {
    let mut cmd = Command::new("git");
    cmd.args(["-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-C"])
        .arg(top)
        .args(args);
    if let Some(index) = index {
        cmd.env("GIT_INDEX_FILE", index);
    }
    cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().context("git")?;
    if let (Some(bytes), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(bytes).context("git: stdin")?;
    }
    let out = child.wait_with_output().context("git")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let last = err.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("git {} failed in {}: {last}", args.first().unwrap_or(&""), top.display());
    }
    Ok(out.stdout)
}

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim().to_owned()
}

/// The uncommitted work of the checkout at `top`, read against its HEAD. The repository gains
/// only unreferenced objects, as `git stash create` leaves; nothing the person sees changes.
pub(crate) fn snapshot(top: &Path) -> Result<Carry> {
    let real = PathBuf::from(text(git(top, None, &["rev-parse", "--git-path", "index"], None)?));
    let real = if real.is_absolute() { real } else { top.join(real) };
    let scratch = tempfile::tempdir().context("a scratch folder for the carried index")?;
    let index = scratch.path().join("index");
    if real.exists() {
        std::fs::copy(&real, &index).context("copying the index")?;
    }
    let base = text(git(top, Some(&index), &["rev-parse", "HEAD"], None)?);
    git(top, Some(&index), &["add", "--update", "--", "."], None)?;
    let untracked =
        git(top, Some(&index), &["ls-files", "-z", "--others", "--exclude-standard"], None)?;
    let (mut keep, mut left_out) = (Vec::new(), Vec::new());
    for path in untracked.split(|b| *b == 0).filter(|p| !p.is_empty()) {
        let why = if path.ends_with(b"/") {
            Some("a nested git repository")
        } else {
            cmux_git::secrets::reason(top, path)
        };
        match why {
            Some(why) => left_out.push((String::from_utf8_lossy(path).into_owned(), why.into())),
            None => {
                keep.extend_from_slice(path);
                keep.push(0);
            }
        }
    }
    if !keep.is_empty() {
        git(
            top,
            Some(&index),
            &["add", "--pathspec-from-file=-", "--pathspec-file-nul", "--"],
            Some(&keep),
        )?;
    }
    let tree = text(git(top, Some(&index), &["write-tree"], None)?);
    let diff = ["diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv"];
    let mut args = diff.to_vec();
    args.extend(["--src-prefix=a/", "--dst-prefix=b/", &base, &tree]);
    let patch = git(top, Some(&index), &args, None)?;
    if patch.len() > MAX_CARRY_BYTES {
        bail!(
            "its uncommitted changes are {} MiB, more than the {} MiB a move carries: commit them",
            patch.len() / (1024 * 1024),
            MAX_CARRY_BYTES / (1024 * 1024)
        );
    }
    let names =
        git(top, Some(&index), &["diff", "--name-only", "-z", "--no-renames", &base, &tree], None)?;
    let files = names.split(|b| *b == 0).filter(|p| !p.is_empty()).count();
    Ok(Carry { base, patch, files, left_out })
}

/// The fixed script that reads a source machine's carry (`--from`): the checkout on stdin.
pub(crate) const CARRY_OUT_SCRIPT: &str =
    r#"PATH="$HOME/.local/bin:$PATH"; read -r top || exit 2; acpmux carry-out -- "$top""#;

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

#[cfg(test)]
#[path = "session_move_carry_tests.rs"]
mod tests;
