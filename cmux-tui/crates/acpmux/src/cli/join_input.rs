//! The single stdin reader shared by cloud and pairing host joins.

#[cfg(test)]
use anyhow::Context;
use anyhow::{Result, anyhow};
use std::io::IsTerminal;
#[cfg(test)]
use std::io::Read;
use zeroize::Zeroizing;

pub const MAX_BYTES: u64 = 4096;

/// Read one join value. Cloud tokens require a newline; legacy pairing tickets
/// also accept EOF immediately after the ticket. Neither path prints its input.
/// The installer supplies a complete value, then closes its pipe. A fixed
/// deadline covers the whole read (including slow writers), not each byte.
pub(crate) fn read_stdin_line(allow_empty: bool) -> Result<Option<Zeroizing<String>>> {
    let input = std::io::stdin();
    if input.is_terminal() {
        return if allow_empty { Ok(None) } else { Err(malformed()) };
    }
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        use std::time::{Duration, Instant};
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut bytes = Zeroizing::new(Vec::new());
        let input = input.lock();
        let fd = input.as_raw_fd();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return if bytes.is_empty() && allow_empty { Ok(None) } else { Err(malformed()) };
            }
            let mut readiness = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            // SAFETY: readiness points to one live pollfd; the borrowed stdin
            // descriptor remains open until this scope ends.
            let ready = unsafe {
                libc::poll(&mut readiness, 1, left.as_millis().min(i32::MAX as u128) as _)
            };
            if ready < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(malformed());
            }
            if ready == 0 {
                continue;
            }
            let mut chunk = [0u8; 512];
            // SAFETY: chunk is writable for its entire length and stdin remains locked.
            let count = unsafe { libc::read(fd, chunk.as_mut_ptr().cast(), chunk.len()) };
            if count < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(malformed());
            }
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(chunk.get(..count as usize).unwrap_or_default());
            if bytes.len() as u64 > MAX_BYTES {
                return Err(malformed());
            }
        }
        if bytes.is_empty() && allow_empty {
            return Ok(None);
        }
        parse_line(&bytes).map(Some).map_err(|_| malformed())
    }
    #[cfg(not(unix))]
    {
        Err(malformed())
    }
}

fn malformed() -> anyhow::Error {
    crate::cli::errors::AppError::new(
        crate::cli::errors::Code::Usage,
        "join.malformed",
        "stdin must contain one join value within two seconds",
    )
    .with_exit(2)
    .into()
}

#[cfg(test)]
pub(crate) fn read_line(input: impl Read) -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::new());
    input.take(MAX_BYTES + 1).read_to_end(&mut bytes).context("read join value from stdin")?;
    parse_line(&bytes)
}

fn parse_line(bytes: &[u8]) -> Result<Zeroizing<String>> {
    if bytes.len() as u64 > MAX_BYTES {
        return Err(anyhow!("stdin holds more than a join value"));
    }
    let text = std::str::from_utf8(bytes).map_err(|_| anyhow!("join value is not text"))?;
    if text.trim_start().starts_with("cmj_") && !text.ends_with('\n') {
        return Err(anyhow!("join value must be newline terminated"));
    }
    let had_newline = text.ends_with('\n');
    let line = match text.strip_suffix('\n') {
        Some(line) => line.strip_suffix('\r').unwrap_or(line),
        None => text,
    };
    if !had_newline && line.ends_with('\r') {
        return Err(anyhow!("stdin must hold one join value line"));
    }
    if line.contains(['\n', '\r']) {
        return Err(anyhow!("stdin must hold one join value line and nothing else"));
    }
    let value = line.trim();
    if value.is_empty() {
        return Err(anyhow!("join value is empty"));
    }
    Ok(Zeroizing::new(value.to_owned()))
}

/// Reject cloud credentials in argv before status, idempotence or any stdin read.
pub(crate) fn validate_arguments(
    ticket: Option<&str>,
    hub: bool,
    replace: bool,
    status: bool,
) -> Result<()> {
    if let Some(ticket) = ticket {
        let message = if ticket.starts_with("cmj_") {
            Some("join token must be provided on stdin")
        } else if hub || replace || status {
            Some("a positional pairing ticket cannot use cloud join flags")
        } else {
            None
        };
        if let Some(message) = message {
            return Err(crate::cli::errors::AppError::new(
                crate::cli::errors::Code::Usage,
                "join.malformed",
                message,
            )
            .with_exit(2)
            .into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{parse_line, validate_arguments};

    #[test]
    fn accepts_one_trimmed_line_only() {
        assert_eq!(&*parse_line(b" cmj_abc \n").unwrap(), "cmj_abc");
        assert_eq!(&*parse_line(b"cmxt1.ticket\r\n").unwrap(), "cmxt1.ticket");
        assert_eq!(&*parse_line(b"cmxt1.ticket").unwrap(), "cmxt1.ticket");
        assert!(parse_line(b"cmxt1.ticket\r").is_err());
        assert!(parse_line(b"cmj_abc").is_err());
        assert!(parse_line(b"cmj_abc\nsecond\n").is_err());
        assert!(parse_line(b"\xff\n").is_err());
    }
    #[test]
    fn cloud_token_in_argv_is_refused_with_every_flag_combination() {
        for hub in [false, true] {
            for replace in [false, true] {
                for status in [false, true] {
                    let error =
                        validate_arguments(Some("cmj_secret"), hub, replace, status).unwrap_err();
                    assert!(!error.to_string().contains("cmj_secret"));
                }
            }
        }
        assert!(validate_arguments(Some("cmxt1.legacy"), false, false, false).is_ok());
        assert!(validate_arguments(Some("cmxt1.legacy"), true, false, false).is_err());
        assert!(validate_arguments(None, true, true, false).is_ok());
    }
}
