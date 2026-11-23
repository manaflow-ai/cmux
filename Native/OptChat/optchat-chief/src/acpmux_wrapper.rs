//! acpmux's `ACPMUX_BIN` wrapper script (F3 of #39020). An acpmux daemon that runs under a host
//! prefix (`<cmux> acp daemon run`) with no `acpmux` alias beside the host binary gives its agents
//! a small script as `ACPMUX_BIN` (acpmux `cli_caller::bin_choice`, written by `install_wrapper`):
//!
//! ```text
//! #!/bin/sh
//! exec '/path/to/cmux' 'acp' "$@"
//! ```
//!
//! A Chief started from such an agent's shell inherits it. Running it starts acpmux as before;
//! but the daemon's process runs the host binary, not the script, so the socket peer check
//! ([`crate::acpmux_peer`]) must compare with the binary the script runs. Only that exact shape
//! names one: a shell word per argument, each in single quotes, the first an absolute path, in a
//! file this user owns and no other user can write. Any other file is no wrapper and is checked
//! as itself.

use std::path::{Path, PathBuf};

/// The largest wrapper read: the script is two short lines.
const MOST: u64 = 4096;

/// The executable `path` runs when it is acpmux's wrapper script, else `None`. Only a regular
/// file this user owns that no other user can write (acpmux writes it 0700) names one: a file
/// another user could change could point the check at any binary (review of #39552). The file
/// is checked and read through one open handle, at most [`MOST`] bytes.
pub fn target(path: &Path) -> Option<PathBuf> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    // Non-blocking: a FIFO named as ACPMUX_BIN must not hang the open; it is no file anyway.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    if !meta.is_file() || meta.uid() != me || meta.mode() & 0o022 != 0 {
        return None;
    }
    let mut text = String::new();
    file.take(MOST + 1).read_to_string(&mut text).ok()?;
    if text.len() as u64 > MOST {
        return None;
    }
    parse(&text)
}

/// The executable in wrapper text `script` (`#!/bin/sh\nexec '<exe>' '<word>'... "$@"\n`).
fn parse(script: &str) -> Option<PathBuf> {
    let line = script
        .strip_prefix("#!/bin/sh\nexec ")?
        .strip_suffix(" \"$@\"\n")?;
    let words = words(line)?;
    let exe = PathBuf::from(words.first()?);
    exe.is_absolute().then_some(exe)
}

/// `line` as single-quoted shell words split by one space (`'it'\''s'` is `it's`), or `None`
/// when it holds anything else.
fn words(line: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut rest = line;
    loop {
        let mut word = String::new();
        rest = rest.strip_prefix('\'')?;
        loop {
            let end = rest.find('\'')?;
            word.push_str(&rest[..end]);
            rest = &rest[end + 1..];
            match rest.strip_prefix("\\''") {
                Some(more) => {
                    word.push('\'');
                    rest = more;
                }
                None => break,
            }
        }
        words.push(word);
        if rest.is_empty() {
            return Some(words);
        }
        rest = rest.strip_prefix(' ')?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn w5s_the_wrapper_names_its_executable_and_nothing_else_does() {
        let exe = |s: &str| parse(s).map(|p| p.display().to_string());
        assert_eq!(
            exe("#!/bin/sh\nexec '/A B/it'\\''s/cmux' 'acp' \"$@\"\n").as_deref(),
            Some("/A B/it's/cmux")
        );
        assert_eq!(
            exe("#!/bin/sh\nexec '/a/cmux' \"$@\"\n").as_deref(),
            Some("/a/cmux")
        );
        for other in [
            "#!/bin/sh\nexec 'cmux' 'acp' \"$@\"\n",
            "#!/bin/sh\nexec /a/cmux 'acp' \"$@\"\n",
            "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\necho hi\n",
            "#!/bin/sh\necho hi\nexec '/a/cmux' 'acp' \"$@\"\n",
            "#!/bin/sh\nexec '/a/cmux' 'acp'; rm -rf / \"$@\"\n",
            "#!/bin/sh\nexec '/a/cmux'  'acp' \"$@\"\n",
            "#!/bin/bash\nexec '/a/cmux' 'acp' \"$@\"\n",
        ] {
            assert_eq!(exe(other), None, "{other:?}");
        }
    }
}
