//! `acpmux session move` of a chat whose folder is not in a git checkout (RFD 0066 piece 11):
//! the folder's files go with the chat, not only its path.
//!
//! Before, such a folder was only made (empty) at the same path under the target's home. Now
//! it is packed as one `tar.gz` on the source and unpacked on the target, the way
//! `Folder::Bundle` carries a checkout with no origin: into the folder when it is missing or
//! empty, else into a new one beside it (never into anything already there).
//!
//! What stays on the source, named in a note: `.env` files, keys, credential folders and the
//! always-heavy folders (`node_modules`, `.venv`, `.next`, `__pycache__`, `.gradle`, caches),
//! the same list `cmux link seed` leaves out. A folder over [`MAX_BYTES`] packed is not sent:
//! the move names `--cwd` and `cmux link seed` instead of copying half of it.

use super::*;

/// The most a packed folder may be (compressed bytes) to travel inside a move.
pub(crate) const MAX_BYTES: u64 = 64 << 20;

/// Reads the folder (line 1) and the byte bound (line 2) from stdin. Prints `missing` when the
/// folder is not there, `big N` when its pack is N bytes over the bound, else `ok N` then the
/// pack in base64. Notes for the person go on stderr with the `acpmux move: ` prefix.
pub(crate) const PACK_SCRIPT: &str = r#"read -r d || exit 2; read -r max || exit 2
case "$d" in /*) ;; *) exit 2;; esac
if [ ! -d "$d" ]; then echo missing; exit 0; fi
cd -- "$d" || exit 2
s=$(mktemp -d) || exit 2
trap 'rm -rf -- "$s"' EXIT
tar -czf "$s/t" \
  --exclude='.env' --exclude='.env.*' --exclude='*.pem' --exclude='*.key' \
  --exclude='id_rsa*' --exclude='id_ed25519*' --exclude='.netrc' \
  --exclude='.ssh' --exclude='.aws' --exclude='.gnupg' --exclude='.docker' \
  --exclude='node_modules' --exclude='.venv' --exclude='.next' --exclude='__pycache__' \
  --exclude='.gradle' --exclude='.cache' \
  . 2>"$s/err" || { cat -- "$s/err" >&2; exit 3; }
left=$(find . \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name .netrc -o -name .ssh -o -name .aws -o -name .gnupg -o -name .docker -o -name node_modules -o -name .venv -o -name .next -o -name __pycache__ -o -name .gradle -o -name .cache \) -prune -print 2>/dev/null | head -20 | tr '\n' ' ')
if [ -n "$left" ]; then echo "acpmux move: left on this machine: $left" >&2; fi
n=$(wc -c <"$s/t" | tr -d ' ')
if [ "$n" -gt "$max" ]; then echo "big $n"; exit 0; fi
echo "ok $n"
base64 <"$s/t" | tr -d '\n'
echo"#;

/// Unpacks a pack on the target: the folder on line 1, then the `tar.gz` bytes. Prints the
/// folder's real path (a new one beside it when it already holds anything).
pub(crate) const UNPACK_SCRIPT: &str = r#"read -r d || exit 2
case "$d" in /*) ;; *) exit 2;; esac
if [ -e "$d" ] && [ -n "$(ls -A -- "$d" 2>/dev/null)" ]; then
  d=$(mktemp -d "$d.moved.XXXXXX") || exit 1
  echo "acpmux move: $d already held files: the folder's files went into a new folder beside it" >&2
else
  mkdir -p -- "$d" || exit 1
fi
b=$(mktemp) || exit 1
trap 'rm -f -- "$b"' EXIT
cat >"$b" || exit 1
tar -xzf "$b" -C "$d" || exit 1
cd -- "$d" && pwd -P"#;

/// What [`pack_folder`] read.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Packed {
    /// The folder is not on the source: only its path moves, as before.
    Missing,
    /// The pack is this many bytes, over the bound; nothing is carried.
    TooBig(u64),
    /// The `tar.gz` bytes.
    Files(Vec<u8>),
}

/// [`PACK_SCRIPT`] on the source (this machine, or the ssh host `ssh`) for `dir`.
pub(crate) fn pack_folder(ssh: Option<&str>, dir: &Path) -> Result<Packed> {
    use base64::Engine as _;
    let input = format!("{}\n{MAX_BYTES}\n", dir.display());
    let out = match ssh {
        None => run_here(PACK_SCRIPT, input.as_bytes())?,
        Some(ssh) => crate::cli::hosts::Remote::exec(
            &crate::cli::hosts::SshRemote(ssh),
            PACK_SCRIPT,
            Some(input.as_bytes()),
        )?,
    };
    if !out.ok {
        let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("packing {} failed: {last}", dir.display());
    }
    for note in out.stderr.lines().filter_map(|l| l.strip_prefix(FOLDER_NOTE)) {
        eprintln!("move: {note}");
    }
    let mut lines = out.stdout.lines();
    let first = lines.next().unwrap_or_default().trim();
    if first == "missing" {
        return Ok(Packed::Missing);
    }
    if let Some(n) = first.strip_prefix("big ") {
        return Ok(Packed::TooBig(n.parse().unwrap_or(0)));
    }
    if !first.starts_with("ok ") {
        bail!("packing {} answered {first:?}", dir.display());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(lines.next().unwrap_or_default().trim())?;
    Ok(Packed::Files(bytes))
}

/// [`UNPACK_SCRIPT`] on the ssh host `host` (this machine when empty); the folder there.
pub(crate) fn unpack_folder(host: &str, cwd: &str, pack: &[u8]) -> Result<String> {
    let mut input = format!("{cwd}\n").into_bytes();
    input.extend_from_slice(pack);
    let out = if host.is_empty() {
        run_here(UNPACK_SCRIPT, &input)?
    } else {
        crate::cli::hosts::Remote::exec(
            &crate::cli::hosts::SshRemote(host),
            UNPACK_SCRIPT,
            Some(&input),
        )?
    };
    let host = if host.is_empty() { "this machine" } else { host };
    if !out.ok {
        return Err(folder_failure(host, &out));
    }
    for note in out.stderr.lines().filter_map(|l| l.strip_prefix(FOLDER_NOTE)) {
        eprintln!("move: {host}: {}", note.trim());
    }
    let path = out.stdout.lines().last().unwrap_or_default().trim().to_owned();
    if !(path.starts_with('/') && crate::cli::hosts::plain_path(&path)) {
        bail!("{host} answered no plain folder path for the chat");
    }
    Ok(path)
}

#[cfg(test)]
#[path = "session_move_files_tests.rs"]
mod tests;
