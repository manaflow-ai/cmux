//! A chat's folder as a snapshot carries it (the design's "Copy").
//!
//! The git form is `session_move_carry`'s: the base commit the remote already has, a bundle of
//! the local commits past it, and one binary patch of the uncommitted work against HEAD, with
//! untracked files that look like secrets left behind. A folder that is no repository, or one
//! whose remote has none of its commits, goes as a tar.
//!
//! Everything here blocks (it runs `git`): call it off the async workers.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
// Each child ends with its handle (`cmux_process::Child`): none outlives the copy it is for.
use cmux_process::{Command, Stdio};

use crate::auto_session::import::BASE_REF;
use crate::cli::hosts::RemoteOut;
use crate::cli::session_move_carry::{self, Carry};

/// A chat's folder, read now.
#[derive(Debug)]
pub(crate) enum Folder {
    Git(GitFolder),
    Plain(PlainFolder),
}

/// A checkout with a remote that has some commit of its history.
#[derive(Debug)]
pub(crate) struct GitFolder {
    /// `origin`'s URL, without a login.
    pub remote: String,
    pub branch: String,
    /// The newest commit of HEAD's history a remote branch has.
    pub base: String,
    /// `git bundle` of `base..HEAD`; empty when HEAD is the base.
    pub bundle: Vec<u8>,
    /// The uncommitted work against HEAD (`git diff --binary`); empty when there is none.
    pub patch: Vec<u8>,
    /// The tree of the folder as this snapshot has it: what a leftover patch is cut against.
    pub tree: String,
}

/// A folder that goes whole.
#[derive(Debug)]
pub(crate) struct PlainFolder {
    pub tar: Vec<u8>,
}

/// Runs one fixed script on this machine, `input` on its stdin.
pub(super) fn sh(script: &str, input: &[u8]) -> Result<RemoteOut> {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("sh")?;
    if let Some(mut stdin) = child.stdin.take() {
        // A script that exits early closes its stdin: its exit says why.
        let _ = stdin.write_all(input);
    }
    let out = child.wait_with_output()?;
    Ok(RemoteOut {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// `git -C dir args`: its stdout, or None when it failed.
fn git(dir: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "core.fsmonitor=false", "-c", "core.quotepath=off"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then_some(out.stdout)
}

fn line(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim().to_owned()
}

/// The checkout's top folder, when `cwd` is in one.
pub(crate) fn top_of(cwd: &Path) -> Option<PathBuf> {
    let top = line(git(cwd, &["rev-parse", "--show-toplevel"])?);
    (!top.is_empty()).then(|| PathBuf::from(top))
}

/// `origin`'s URL without a login, and the branch checked out (`HEAD` when detached).
pub(crate) fn remote_and_branch(top: &Path) -> Option<(String, String)> {
    let remote = line(git(top, &["remote", "get-url", "origin"])?);
    if remote.is_empty() {
        return None;
    }
    let branch = git(top, &["rev-parse", "--abbrev-ref", "HEAD"]).map(line).unwrap_or_default();
    let branch = if branch.is_empty() { "HEAD".to_owned() } else { branch };
    Some((crate::run_elsewhere::without_login(&remote), branch))
}

/// The newest commit of HEAD's history that a remote branch has: the merge base with HEAD's
/// upstream, else with every remote branch this checkout knows and the base the folder's last
/// imported snapshot named (a folder an import made fetched that commit by its id, so it has
/// no branch of the remote). None when the remote has none of it (or nothing was ever fetched
/// or pushed).
fn base_of(top: &Path) -> Option<String> {
    let upstream = git(top, &["merge-base", "HEAD", "@{upstream}"]).map(line);
    if let Some(base) = upstream.filter(|base| !base.is_empty()) {
        return Some(base);
    }
    let known = ["for-each-ref", "--format=%(objectname)", "refs/remotes", BASE_REF];
    let refs = line(git(top, &known)?);
    let mut args = vec!["merge-base", "HEAD"];
    args.extend(refs.lines().filter(|name| !name.is_empty()));
    if args.len() == 2 {
        return None;
    }
    let base = line(git(top, &args)?);
    (!base.is_empty()).then_some(base)
}

/// The fixed script that writes the tree of HEAD with a patch applied: the top folder and the
/// commit on two lines of stdin, the patch after them. Prints the tree. Nothing the person sees
/// changes: the index it uses is a scratch one, and the objects are unreferenced.
const TREE_SCRIPT: &str = r#"read -r top || exit 2; read -r base || exit 2
cd -- "$top" || exit 2
s=$(mktemp -d) || exit 2
trap 'rm -rf -- "$s"' EXIT
cat >"$s/patch" || exit 2
GIT_INDEX_FILE="$s/index"; export GIT_INDEX_FILE
git read-tree "$base" || exit 3
if [ -s "$s/patch" ]; then
  git -c core.fsmonitor=false apply --cached --binary --whitespace=nowarn "$s/patch" || exit 3
fi
git write-tree"#;

/// The fixed script that diffs two trees: the top folder and the two trees on three lines of
/// stdin. Prints the files that differ (one line, NUL-separated, base64), then the binary patch
/// in base64. A moved file is a deletion and an addition in the patch, each with the blob ids
/// that `apply.rs` merges from.
const DIFF_SCRIPT: &str = r#"read -r top || exit 2; read -r from || exit 2; read -r to || exit 2
cd -- "$top" || exit 2
g() { git -c core.fsmonitor=false -c core.quotepath=false "$@"; }
g diff --name-only -z --no-renames "$from" "$to" | base64 | tr -d '\n' || exit 3
echo
g diff --binary --full-index --no-renames --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$from" "$to" | base64 | tr -d '\n' || exit 3
echo"#;

fn decode(text: &str) -> Result<Vec<u8>> {
    use base64::Engine as _;
    let text: String = text.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    Ok(base64::engine::general_purpose::STANDARD.decode(text)?)
}

fn failed(out: &RemoteOut, what: &str) -> anyhow::Error {
    let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
    anyhow!("{what} failed: {last}")
}

/// The uncommitted work of the checkout at `top` against its HEAD, secrets left behind, and the
/// tree of the folder with it.
fn work_tree(top: &Path) -> Result<(Carry, String)> {
    let carry = session_move_carry::snapshot(&sh, top, true)?;
    let mut input = format!("{}\n{}\n", top.to_string_lossy(), carry.base).into_bytes();
    input.extend_from_slice(&carry.patch);
    let out = sh(TREE_SCRIPT, &input)?;
    if !out.ok {
        return Err(failed(&out, "reading the folder's tree"));
    }
    let tree = out.stdout.trim().to_owned();
    if tree.len() < 40 || !tree.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("the folder answered no tree");
    }
    Ok((carry, tree))
}

/// `git bundle` of `base..head`, or nothing when they are the same commit.
fn bundle(top: &Path, base: &str, head: &str) -> Result<Vec<u8>> {
    if base == head {
        return Ok(Vec::new());
    }
    let scratch = tempfile::tempdir().context("a scratch folder")?;
    let file = scratch.path().join("auto.bundle");
    let file_text = file.to_string_lossy().into_owned();
    // The bundle names HEAD, so the other side fetches it without knowing the branch.
    let range = format!("{base}..HEAD");
    git(top, &["bundle", "create", "--quiet", &file_text, &range])
        .ok_or_else(|| anyhow!("bundling the local commits failed"))?;
    std::fs::read(&file).context("the bundle")
}

/// The folder is past the size a snapshot may have.
#[derive(Debug)]
pub(crate) struct TooLarge;

impl std::fmt::Display for TooLarge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the folder is too large to keep a Cloud copy")
    }
}

impl std::error::Error for TooLarge {}

/// Why an untracked file stays behind (`cmux_git::secrets`), or None when it goes.
#[cfg(unix)]
fn leave_out(top: &Path, relative: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt as _;
    cmux_git::secrets::reason(top, relative.as_os_str().as_bytes()).is_some()
}

/// The secrets rule reads raw path bytes, which only unix has: elsewhere no untracked file goes.
#[cfg(not(unix))]
fn leave_out(_top: &Path, _relative: &Path) -> bool {
    true
}

/// Every file under `top`, as paths from it, links not followed. `.git` is not entered.
fn walk(top: &Path, under: &Path, found: &mut Vec<PathBuf>) -> Result<()> {
    for entry in std::fs::read_dir(top.join(under)).context("reading the folder")? {
        let entry = entry?;
        let relative = under.join(entry.file_name());
        let kind = entry.file_type()?;
        if super::ignore::ignored(Path::new(&entry.file_name()), kind.is_dir()) {
            continue;
        }
        if kind.is_dir() {
            if entry.file_name() != ".git" {
                walk(top, &relative, found)?;
            }
        } else {
            found.push(relative);
        }
    }
    Ok(())
}

/// The files of `top` a tar takes, each with whether git tracks it. In a repository: what git
/// tracks and what is untracked and not ignored. Elsewhere: every file, none tracked.
fn listed(top: &Path) -> Result<Vec<(PathBuf, bool)>> {
    let paths = |bytes: Vec<u8>, tracked: bool| -> Vec<(PathBuf, bool)> {
        bytes
            .split(|b| *b == 0)
            .filter(|name| !name.is_empty() && !name.ends_with(b"/"))
            .map(|name| (PathBuf::from(String::from_utf8_lossy(name).into_owned()), tracked))
            .collect()
    };
    if top_of(top).is_some() {
        let tracked = git(top, &["ls-files", "-z", "--cached"]).unwrap_or_default();
        let others =
            git(top, &["ls-files", "-z", "--others", "--exclude-standard"]).unwrap_or_default();
        let mut files = paths(tracked, true);
        files.extend(paths(others, false));
        return Ok(files);
    }
    let mut found = Vec::new();
    walk(top, Path::new(""), &mut found)?;
    Ok(found.into_iter().map(|path| (path, false)).collect())
}

/// The folder as a tar of at most `max` bytes of files. A file git does not track that looks
/// like a secret stays behind, as in the git form.
fn plain(cwd: &Path, max: u64) -> Result<PlainFolder> {
    let top = top_of(cwd).unwrap_or_else(|| cwd.to_path_buf());
    let mut tar = tar::Builder::new(Vec::new());
    tar.follow_symlinks(false);
    let mut total = 0u64;
    for (relative, tracked) in listed(&top)? {
        if !tracked && leave_out(&top, &relative) {
            continue;
        }
        let path = top.join(&relative);
        // A file that went away since the listing is not in the tar.
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        total = total.saturating_add(meta.len());
        if total > max {
            return Err(TooLarge.into());
        }
        tar.append_path_with_name(&path, &relative)
            .with_context(|| format!("packing {}", relative.display()))?;
    }
    Ok(PlainFolder { tar: tar.into_inner().context("the folder's tar")? })
}

/// Reads the chat's folder at `cwd`. `max`: the most bytes a tar's files may add up to; past it
/// the error is [`TooLarge`].
pub(crate) fn read(cwd: &Path, max: u64) -> Result<Folder> {
    if cwd.to_string_lossy().contains('\n') {
        bail!("the chat's folder has a line break in its name");
    }
    let git_form = top_of(cwd).and_then(|top| {
        let (remote, branch) = remote_and_branch(&top)?;
        let base = base_of(&top)?;
        Some((top, remote, branch, base))
    });
    let Some((top, remote, branch, base)) = git_form else {
        return plain(cwd, max).map(Folder::Plain);
    };
    let (carry, tree) = work_tree(&top)?;
    let bundle = bundle(&top, &base, &carry.base)?;
    Ok(Folder::Git(GitFolder { remote, branch, base, bundle, patch: carry.patch, tree }))
}

/// What the folder holds now that the snapshot whose tree is `anchor` did not: the files, and
/// one binary patch from that tree to the folder as it is. None when nothing differs.
pub(crate) fn since(top: &Path, anchor: &str) -> Result<Option<(Vec<String>, Vec<u8>)>> {
    let (_, tree) = work_tree(top)?;
    if tree == anchor {
        return Ok(None);
    }
    let input = format!("{}\n{anchor}\n{tree}\n", top.to_string_lossy());
    let out = sh(DIFF_SCRIPT, input.as_bytes())?;
    if !out.ok {
        return Err(failed(&out, "reading what changed since the last copy"));
    }
    let mut lines = out.stdout.lines();
    let names = decode(lines.next().unwrap_or_default()).context("the changed files")?;
    let patch = decode(lines.next().unwrap_or_default()).context("the patch")?;
    let files: Vec<String> = names
        .split(|b| *b == 0)
        .filter(|name| !name.is_empty())
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .collect();
    if files.is_empty() || patch.is_empty() {
        return Ok(None);
    }
    Ok(Some((files, patch)))
}
