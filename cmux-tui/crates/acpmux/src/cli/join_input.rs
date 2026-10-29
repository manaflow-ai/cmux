//! The single stdin reader shared by cloud and pairing host joins.

use anyhow::{Context, Result, anyhow};
use std::io::{IsTerminal, Read};
use zeroize::Zeroizing;

pub const MAX_BYTES: u64 = 4096;

/// Read one join value. Cloud tokens require a newline; legacy pairing tickets
/// also accept EOF immediately after the ticket. Neither path prints its input.
pub fn read_stdin_line() -> Result<Zeroizing<String>> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Usage,
            "join.malformed",
            "pass the join value on stdin",
        )
        .with_exit(2)
        .into());
    }
    read_line(stdin.lock()).map_err(|_| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Usage,
            "join.malformed",
            "stdin must contain one bounded join value line",
        )
        .with_exit(2)
        .into()
    })
}

pub(crate) fn read_line(input: impl Read) -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::new());
    input.take(MAX_BYTES + 1).read_to_end(&mut bytes).context("read join value from stdin")?;
    parse_line(&bytes)
}

fn parse_line(bytes: &[u8]) -> Result<Zeroizing<String>> {
    if bytes.len() as u64 > MAX_BYTES {
        return Err(anyhow!("stdin holds more than a join value"));
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| anyhow!("join value is not text"))?;
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
