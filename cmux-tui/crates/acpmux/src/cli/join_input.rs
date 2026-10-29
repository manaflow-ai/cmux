//! The single stdin reader shared by cloud and pairing host joins.

use anyhow::{Context, Result, anyhow};
use std::io::{IsTerminal, Read};
use zeroize::Zeroizing;

pub const MAX_BYTES: u64 = 4096;

/// Read one newline-terminated join value without ever putting it in argv.
/// Both join protocols use this reader so their bounds and line handling stay
/// identical.
pub fn read_stdin_line() -> Result<Zeroizing<String>> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        return Err(anyhow!("pass the join value on stdin"));
    }
    let mut bytes = Zeroizing::new(Vec::new());
    stdin
        .lock()
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .context("read join value from stdin")?;
    parse_line(&bytes)
}

fn parse_line(bytes: &[u8]) -> Result<Zeroizing<String>> {
    if bytes.len() as u64 > MAX_BYTES { return Err(anyhow!("stdin holds more than a join value")); }
    let text = std::str::from_utf8(&bytes).map_err(|_| anyhow!("join value is not text"))?;
    let line = text
        .strip_suffix('\n')
        .ok_or_else(|| anyhow!("join value must be newline terminated"))?;
    let line = line.strip_suffix('\r').unwrap_or(line);
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
    use super::parse_line;

    #[test]
    fn accepts_one_trimmed_line_only() {
        assert_eq!(&*parse_line(b" cmj_abc \n").unwrap(), "cmj_abc");
        assert_eq!(&*parse_line(b"cmxt1.ticket\r\n").unwrap(), "cmxt1.ticket");
        assert!(parse_line(b"cmj_abc").is_err());
        assert!(parse_line(b"cmj_abc\nsecond\n").is_err());
        assert!(parse_line(b"\xff\n").is_err());
    }
}
