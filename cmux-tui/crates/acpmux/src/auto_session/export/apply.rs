//! A kept leftover patch going into the chat's folder (the pane's Apply).
//!
//! The folder is the person's, and it usually has uncommitted work: the leftover's own change
//! until a handback, the Cloud's uncommitted work after one. So the patch is merged three ways
//! on trees, beside the folder, and only a merge with no conflict is written:
//!
//! - base: the files as the patch found them, from the blob ids the patch names;
//! - ours: the same files as the folder has them now, tracked or not;
//! - theirs: base with the patch applied.
//!
//! The person's index is read and never written (every index here is a scratch one), so what
//! they staged stays staged. A change that is in the folder already merges to the folder as it
//! is: that counts as applied. A conflict writes nothing at all. The repository gains only
//! unreferenced objects, as `git stash create` leaves.
//!
//! Blocking (it runs `git`): call it off the async workers.

use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};

use super::folder::sh;

/// The fixed script that merges a patch into the folder: the top folder on the first line of
/// stdin, the patch after it. Exit 4: the folder changed the same lines (nothing was written).
/// Exit 3: git could not merge (nothing was written). Exit 5: a file could not be written.
///
/// `git merge-tree --write-tree` finds its base from commits, so the three trees get commits
/// that nothing refers to. `--build-fake-ancestor` only builds the base index: it applies
/// nothing.
const APPLY_SCRIPT: &str = r#"read -r top || exit 2
cd -- "$top" || exit 2
s=$(mktemp -d) || exit 2
trap 'rm -rf -- "$s"' EXIT
cat >"$s/patch" || exit 2
[ -s "$s/patch" ] || exit 0
# Every path is a file name, never pathspec magic.
GIT_LITERAL_PATHSPECS=1; export GIT_LITERAL_PATHSPECS
GIT_AUTHOR_NAME=cmux; GIT_AUTHOR_EMAIL=auto@cmux.invalid
GIT_COMMITTER_NAME=cmux; GIT_COMMITTER_EMAIL=auto@cmux.invalid
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
g() { git -c core.fsmonitor=false -c core.quotepath=false "$@"; }
# `i NAME ...`: git on the scratch index NAME.
i() { n=$1; shift; GIT_INDEX_FILE="$s/$n" git -c core.fsmonitor=false -c core.quotepath=false "$@"; }
g apply --build-fake-ancestor="$s/base" "$s/patch" || exit 3
cp -- "$s/base" "$s/theirs" || exit 2
i theirs apply --cached --binary --whitespace=nowarn "$s/patch" || exit 3
base=$(i base write-tree) && theirs=$(i theirs write-tree) || exit 3
{ i base ls-files -z && i theirs ls-files -z; } >"$s/names" || exit 3
# The files the patch touches that the folder has now.
xargs -0 sh -c 'for p do if [ -e "$p" ] || [ -L "$p" ]; then printf "%s\000" "$p"; fi; done' sh <"$s/names" >"$s/here" || exit 3
if [ -s "$s/here" ]; then
  i ours add -f --sparse --pathspec-from-file="$s/here" --pathspec-file-nul || exit 3
  ours=$(i ours write-tree) || exit 3
else
  ours=$(g mktree </dev/null) || exit 3
fi
c0=$(g commit-tree "$base" -m base </dev/null) || exit 3
c1=$(g commit-tree "$ours" -p "$c0" -m folder </dev/null) || exit 3
c2=$(g commit-tree "$theirs" -p "$c0" -m kept </dev/null) || exit 3
g merge-tree --write-tree --name-only --no-messages "$c1" "$c2" >"$s/merged"
rc=$?
if [ "$rc" -eq 1 ]; then
  echo "the folder also changed: $(sed 1d "$s/merged" | tr '\n' ' ')" >&2
  exit 4
fi
[ "$rc" -eq 0 ] || exit 3
merged=$(sed -n 1p "$s/merged")
# The change is in the folder already.
[ "$merged" = "$ours" ] && exit 0
i out read-tree "$merged" || exit 3
g diff --name-only -z --no-renames --diff-filter=D "$ours" "$merged" >"$s/gone" || exit 3
g diff --name-only -z --no-renames --diff-filter=d "$ours" "$merged" >"$s/put" || exit 3
if [ -s "$s/gone" ]; then xargs -0 rm -f -- <"$s/gone" || exit 5; fi
if [ -s "$s/put" ]; then i out checkout-index -f -z --stdin <"$s/put" || exit 5; fi
exit 0"#;

/// Applies the kept patch at `patch` to the folder at `top`, merging where the folder moved
/// on. An error means the folder is as it was, unless a file could not be written.
pub(crate) fn apply(top: &Path, patch: &Path) -> Result<()> {
    let top_line = top.to_string_lossy();
    if top_line.contains('\n') {
        bail!("the chat's folder has a line break in its name");
    }
    let mut input = format!("{top_line}\n").into_bytes();
    input.extend(std::fs::read(patch).context("reading the kept changes")?);
    let out = sh(APPLY_SCRIPT, &input)?;
    if out.ok {
        return Ok(());
    }
    let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
    Err(anyhow!("the changes do not apply to the folder as it is now: {last}"))
}
