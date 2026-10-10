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

use std::io::{BufRead, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use zeroize::Zeroizing;

use crate::config::folder_profiles;
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
/// what goes to its stdin. `stdin` holds the value: it is zeroed on drop.
#[derive(PartialEq, Eq)]
pub struct StoreCommand {
    pub argv: Vec<String>,
    pub stdin: Zeroizing<String>,
}

impl std::fmt::Debug for StoreCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoreCommand").field("argv", &self.argv).field("stdin", &"***").finish()
    }
}

/// The store command for `os` ("macos" or any other unix). The value is
/// copied once, into `stdin`, sized up front so it never reallocates.
pub fn store_command(os: &str, id: &str, key: &str, value: &str) -> Result<StoreCommand> {
    if value.is_empty() {
        bail!("the value is empty");
    }
    if value.contains(['\n', '\r', '\0']) {
        bail!("the value has a line break or NUL byte; a secret must be one line");
    }
    let account = format!("{id}/{key}");
    let label = format!("cmux harness {id} {key}");
    Ok(if os == "macos" {
        let head = format!(
            "add-generic-password -U -s {SERVICE} -a {} -l {} -w ",
            security_quote(&account),
            security_quote(&label)
        );
        // Every value byte may need an escape, plus the quotes and line end.
        let mut stdin = Zeroizing::new(String::with_capacity(head.len() + 2 * value.len() + 3));
        stdin.push_str(&head);
        push_security_quoted(&mut stdin, value);
        stdin.push('\n');
        StoreCommand { argv: vec!["/usr/bin/security".into(), "-i".into()], stdin }
    } else {
        let mut stdin = Zeroizing::new(String::with_capacity(value.len()));
        stdin.push_str(value);
        StoreCommand {
            argv: ["secret-tool", "store", "--label", &label, "service", SERVICE, "account"]
                .iter()
                .map(|s| (*s).to_owned())
                .chain(std::iter::once(account))
                .collect(),
            stdin,
        }
    })
}

/// A word for `security -i`'s command parser: double quotes, with `\` and
/// `"` escaped.
fn security_quote(text: &str) -> String {
    let mut out = String::with_capacity(2 * text.len() + 2);
    push_security_quoted(&mut out, text);
    out
}

/// Appends `text` as a `security -i` word to `out` without a temporary copy.
fn push_security_quoted(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        if matches!(c, '\\' | '"') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
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

/// Store the secret and point the profile at it. `store` runs a
/// [`StoreCommand`] (tests pass a fake). Only a catalog harness.
pub fn secret_set(
    id: &str,
    key: &str,
    value: &str,
    cfg: &Config,
    store: &dyn Fn(&StoreCommand) -> Result<()>,
) -> Result<FileChange> {
    secret_set_in(id, key, value, cfg, None, store)
}

/// [`secret_set`] for a command run in `cwd`: a folder profile of `cwd` or a
/// folder above it (`<folder>/.cmux/harnesses/<id>.toml`) is a known id too.
/// Its file is never edited here (it belongs to the repository); the
/// reference line is printed for the user to add.
pub fn secret_set_in(
    id: &str,
    key: &str,
    value: &str,
    cfg: &Config,
    cwd: Option<&Path>,
    store: &dyn Fn(&StoreCommand) -> Result<()>,
) -> Result<FileChange> {
    if !profiles::valid_id(id) {
        bail!("id {id:?} must be 1-40 lowercase letters, digits or '-'");
    }
    if !profiles::valid_env_key(key) {
        bail!("{key:?} is not a valid env variable name");
    }
    // Before the store: a typo must not leave a secret store item behind.
    let folder_file = known_harness(cfg, id, cwd)?;
    store(&store_command(std::env::consts::OS, id, key, value)?)?;
    Ok(match cfg.profile_meta.get(id) {
        Some(meta) if meta.source == ProfileSource::UserFile => {
            let path = PathBuf::from(&meta.source_path);
            match write_reference(&path, id, key) {
                Ok(true) => FileChange::Written(path),
                Ok(false) => FileChange::Unchanged(path),
                Err(reason) => FileChange::Manual { path: Some(meta.source_path.clone()), reason },
            }
        }
        Some(meta) => FileChange::Manual {
            path: Some(meta.source_path.clone()),
            reason: "this profile is not a file in your harness folder".into(),
        },
        None => FileChange::Manual {
            path: folder_file.map(|p| p.display().to_string()),
            reason: "this is a folder profile; cmux does not edit repository files".into(),
        },
    })
}

/// Ok when `id` names a harness of `cfg` (any source: None) or a folder
/// profile file of `cwd` or a folder above it (Some(its path)); else the
/// "unknown harness" error.
pub fn known_harness(cfg: &Config, id: &str, cwd: Option<&Path>) -> Result<Option<PathBuf>> {
    if cfg.profile(id).is_some() {
        return Ok(None);
    }
    let file = cwd.and_then(|cwd| {
        cwd.ancestors()
            .map(|folder| folder_profiles::profile_dir(folder).join(format!("{id}.toml")))
            .find(|file| file.is_file())
    });
    match file {
        Some(file) => Ok(Some(file)),
        None => bail!("unknown harness {id:?}; `cmux harness list` shows the harness ids"),
    }
}

/// Put `KEY = { keychain = "cmux-harness/<id>/<KEY>" }` under `[env]` of the
/// profile file: replace a one-line `KEY = …`, else add it after `[env]`,
/// else append an `[env]` table. Ok(false): the file already had it. The
/// result must parse with the reference in place, or nothing is written.
pub fn write_reference(path: &Path, id: &str, key: &str) -> Result<bool, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read: {e}"))?;
    let want = format!("${{keychain:{}}}", reference(id, key));
    let current = |text: &str| -> Result<Option<String>, String> {
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned());
        match profiles::parse_profile_toml(text, path, stem.as_deref(), ProfileSource::UserFile) {
            Ok((_, profile, _, _)) => Ok(profile.env.get(key).cloned()),
            Err(errors) => {
                Err(errors.into_iter().map(|d| d.message).collect::<Vec<_>>().join("; "))
            }
        }
    };
    if current(&text)?.as_deref() == Some(want.as_str()) {
        return Ok(false);
    }
    let line = reference_line(id, key);
    let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
    let header = |l: &str| l.trim_start().starts_with('[');
    let is_env_header = |l: &str| {
        let t = l.trim();
        t == "[env]" || (t.starts_with("[env]") && t[5..].trim_start().starts_with('#'))
    };
    let env_at = lines.iter().position(|l| is_env_header(l));
    let key_at = env_at.and_then(|start| {
        lines[start + 1..]
            .iter()
            .take_while(|l| !header(l))
            .position(|l| {
                l.trim_start()
                    .strip_prefix(key)
                    .is_some_and(|rest| rest.trim_start().starts_with('='))
            })
            .map(|i| start + 1 + i)
    });
    match (env_at, key_at) {
        (_, Some(at)) => lines[at] = line,
        (Some(at), None) => lines.insert(at + 1, line),
        (None, None) => {
            lines.push(String::new());
            lines.push("[env]".into());
            lines.push(line);
        }
    }
    let mut edited = lines.join("\n");
    edited.push('\n');
    match current(&edited) {
        Ok(Some(v)) if v == want => {}
        Ok(_) => return Err(format!("could not place {key} under [env] safely")),
        Err(e) => return Err(format!("the edited file would not parse: {e}")),
    }
    crate::config::write_atomic(path, edited.as_bytes()).map_err(|e| e.to_string())?;
    Ok(true)
}

/// Read the value: a no-echo prompt on a terminal, else all of stdin with
/// one trailing line break removed.
pub fn read_value(key: &str) -> Result<Zeroizing<String>> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        eprint!("Value for {key} (input hidden): ");
        std::io::stderr().flush()?;
        let value = read_hidden_line()?;
        eprintln!();
        return Ok(value);
    }
    read_secret_from(&mut stdin.lock())
}

/// All of `input` (at most [`MAX_SECRET_BYTES`]) with one trailing line
/// break removed. One buffer, sized before the read, holds the value from
/// the read to the drop (zeroed then), so no reallocation leaves a copy.
pub fn read_secret_from(input: &mut impl Read) -> Result<Zeroizing<String>> {
    let mut buf = Zeroizing::new(Vec::with_capacity(MAX_SECRET_BYTES + 1));
    input.take(MAX_SECRET_BYTES as u64 + 1).read_to_end(&mut buf)?;
    if buf.len() > MAX_SECRET_BYTES {
        bail!("the value is longer than {MAX_SECRET_BYTES} bytes");
    }
    let mut value = match String::from_utf8(std::mem::take(&mut *buf)) {
        Ok(text) => Zeroizing::new(text),
        Err(e) => {
            drop(Zeroizing::new(e.into_bytes()));
            bail!("the value is not UTF-8");
        }
    };
    if value.ends_with('\n') {
        value.pop();
        if value.ends_with('\r') {
            value.pop();
        }
    }
    Ok(value)
}

/// One line from the terminal with echo off; echo is restored on every path.
/// The line goes into one presized buffer that is zeroed on drop; a line
/// longer than [`MAX_SECRET_BYTES`] is refused.
fn read_hidden_line() -> Result<Zeroizing<String>> {
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
    let mut line = Zeroizing::new(String::with_capacity(MAX_SECRET_BYTES + 2));
    let read = std::io::stdin().lock().take(MAX_SECRET_BYTES as u64 + 2).read_line(&mut line);
    // SAFETY: restores the settings read above.
    unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &saved) };
    read?;
    let end = line.trim_end_matches(['\n', '\r']).len();
    line.truncate(end);
    if line.len() > MAX_SECRET_BYTES {
        bail!("the value is longer than {MAX_SECRET_BYTES} bytes");
    }
    Ok(line)
}

/// `cmux harness secret set ID KEY`.
pub async fn set_cmd(id: &str, key: &str) -> Result<()> {
    let cfg = Config::load()?;
    let cwd = std::env::current_dir().ok();
    // Before the prompt: nobody types a secret for a harness that does not exist.
    known_harness(&cfg, id, cwd.as_deref())?;
    let value = read_value(key)?;
    let change =
        secret_set_in(id, key, value.as_str(), &cfg, cwd.as_deref(), &|cmd| run_store(cmd))?;
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
