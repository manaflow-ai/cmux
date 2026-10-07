//! `cmux harness secret set ID KEY` (BRING-YOUR-OWN-HARNESS H4): store a
//! secret for a harness env key in the system secret store and point the
//! user's profile file at it.
//!
//! The value comes from a no-echo prompt on a terminal, else from stdin. It
//! is never printed, logged, or put in a command line (other processes can
//! read argv): on macOS it goes to `security -i` on stdin, elsewhere to
//! `secret-tool store` on stdin. The item is service `cmux-harness`, account
//! `<id>/<KEY>`, so the reference is `{ keychain = "cmux-harness/<id>/<KEY>" }`.
//! A user profile file gets that line under `[env]` (replacing a literal
//! value); any other source gets the line to add by hand.

use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};

use crate::config::profiles;
use crate::config::{Config, ProfileSource};

/// The secret store service every harness secret uses.
pub const SERVICE: &str = "cmux-harness";
/// Largest value read from stdin, in bytes.
pub const MAX_SECRET_BYTES: usize = 64 * 1024;

/// The reference a profile writes for the secret of `id`/`key`.
pub fn reference(id: &str, key: &str) -> String {
    format!("{SERVICE}/{id}/{key}")
}

/// The TOML line that points `key` at its Keychain item.
pub fn reference_line(id: &str, key: &str) -> String {
    format!("{key} = {{ keychain = \"{}\" }}", reference(id, key))
}

/// How to store a value: the program, its arguments (never the value) and
/// what goes to its stdin.
#[derive(Debug, PartialEq, Eq)]
pub struct StoreCommand {
    pub argv: Vec<String>,
    pub stdin: String,
}

/// The store command for `os` (red: not yet).
pub fn store_command(_os: &str, _id: &str, _key: &str, _value: &str) -> Result<StoreCommand> {
    Ok(StoreCommand { argv: vec![], stdin: String::new() })
}

/// A word for `security -i`'s command parser: double quotes, with `\` and
/// `"` escaped.
fn security_quote(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Run the store command. Its output is discarded: `security` may echo.
pub fn run_store(cmd: &StoreCommand) -> Result<()> {
    use std::process::{Command, Stdio};
    use wait_timeout::ChildExt;
    let mut child = Command::new(&cmd.argv[0])
        .args(&cmd.argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| anyhow!("cannot run {}: {e}", cmd.argv[0]))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(cmd.stdin.as_bytes())?;
    }
    match child.wait_timeout(std::time::Duration::from_secs(60))? {
        Some(status) if status.success() => Ok(()),
        Some(status) => bail!("{} failed ({status}); nothing was stored", cmd.argv[0]),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{} did not finish in 60 s; nothing was stored", cmd.argv[0])
        }
    }
}

/// What `secret set` did with the profile.
#[derive(Debug, PartialEq, Eq)]
pub enum FileChange {
    /// The user file now has the reference line.
    Written(PathBuf),
    /// The user file already had it.
    Unchanged(PathBuf),
    /// The line could not be written here; add it by hand.
    Manual { path: Option<String>, reason: String },
}

/// Store the secret and point the profile at it (red: not yet).
pub fn secret_set(
    _id: &str,
    _key: &str,
    _value: &str,
    _cfg: &Config,
    _store: &dyn Fn(&StoreCommand) -> Result<()>,
) -> Result<FileChange> {
    Ok(FileChange::Manual { path: None, reason: "not implemented".into() })
}

/// Put the reference under `[env]` (red: not yet).
pub fn write_reference(_path: &Path, _id: &str, _key: &str) -> Result<bool, String> {
    Ok(false)
}

/// Read the value: a no-echo prompt on a terminal, else all of stdin with
/// one trailing line break removed.
pub fn read_value(key: &str) -> Result<String> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        eprint!("Value for {key} (input hidden): ");
        std::io::stderr().flush()?;
        let value = read_hidden_line()?;
        eprintln!();
        return Ok(value);
    }
    let mut buf = Vec::new();
    stdin.lock().take(MAX_SECRET_BYTES as u64 + 1).read_to_end(&mut buf)?;
    if buf.len() > MAX_SECRET_BYTES {
        bail!("the value is longer than {MAX_SECRET_BYTES} bytes");
    }
    let mut value = String::from_utf8(buf).map_err(|_| anyhow!("the value is not UTF-8"))?;
    if value.ends_with('\n') {
        value.pop();
        if value.ends_with('\r') {
            value.pop();
        }
    }
    Ok(value)
}

/// One line from the terminal with echo off; echo is restored on every path.
fn read_hidden_line() -> Result<String> {
    let fd = libc::STDIN_FILENO;
    let mut saved = std::mem::MaybeUninit::<libc::termios>::uninit();
    // SAFETY: tcgetattr fills `saved` for a valid fd or fails without touching it.
    if unsafe { libc::tcgetattr(fd, saved.as_mut_ptr()) } != 0 {
        bail!("cannot read the terminal settings");
    }
    // SAFETY: tcgetattr succeeded, so `saved` is initialized.
    let saved = unsafe { saved.assume_init() };
    let mut quiet = saved;
    quiet.c_lflag &= !libc::ECHO;
    // SAFETY: a termios copied from tcgetattr, for the same fd.
    if unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &quiet) } != 0 {
        bail!("cannot turn off terminal echo; pipe the value on stdin instead");
    }
    let mut line = String::new();
    let read = std::io::stdin().read_line(&mut line);
    // SAFETY: restores the settings read above.
    unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &saved) };
    read?;
    Ok(line.trim_end_matches(['\n', '\r']).to_owned())
}

/// `cmux harness secret set ID KEY`.
pub async fn set_cmd(id: &str, key: &str) -> Result<()> {
    let cfg = Config::load()?;
    let value = read_value(key)?;
    let change = secret_set(id, key, &value, &cfg, &|cmd| run_store(cmd))?;
    drop(value);
    println!("stored {key} for {id} in the secret store ({})", reference(id, key));
    match change {
        FileChange::Written(path) => println!("wrote the reference into {}", path.display()),
        FileChange::Unchanged(path) => println!("{} already refers to it", path.display()),
        FileChange::Manual { path, reason } => {
            println!(
                "{reason}; add this line under [env]{}:",
                match &path {
                    Some(p) => format!(" in {p}"),
                    None => String::new(),
                }
            );
            println!("  {}", reference_line(id, key));
        }
    }
    super::harness::reload_daemon().await;
    println!("next: cmux harness doctor {id}");
    Ok(())
}

#[cfg(test)]
#[path = "harness_secret_tests.rs"]
mod tests;
