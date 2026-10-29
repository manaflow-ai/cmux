//! Env references in a harness profile: `${keychain:service[/account]}`,
//! `${env:VAR}` and `${file:/abs/path}`, resolved only when a harness starts. Part of
//! `config/profiles.rs`.

use std::collections::BTreeMap;

pub(super) fn is_reference(value: &str) -> bool {
    value.contains("${keychain:") || value.contains("${env:") || value.contains("${file:")
}

/// Largest secret a `file:` reference reads.
const FILE_SECRET_MAX: u64 = 8 * 1024;

/// The secret in `path` (a `file:` reference): an absolute path to a regular
/// file (not a symlink) that only this user owns and can read or write
/// (mode 0600 or narrower), at most 8 KiB, one trailing newline dropped. A
/// short-lived token another process rotates on disk; acpmux never records
/// the value, only the reference.
pub fn file_secret(path: &str) -> Result<String, String> {
    let text = read_owner_only(path)?;
    let text = text.strip_suffix('\n').unwrap_or(&text);
    let text = text.strip_suffix('\r').unwrap_or(text);
    if text.is_empty() || text.contains(['\n', '\r']) {
        return Err(format!("{path}: holds no single-line secret"));
    }
    Ok(text.to_owned())
}

/// The file's text after the owner-only checks (Unix: one O_NOFOLLOW open,
/// every check on that descriptor).
#[cfg(unix)]
fn read_owner_only(path: &str) -> Result<String, String> {
    let p = std::path::Path::new(path);
    if !p.is_absolute() {
        return Err(format!("{path}: a file reference needs an absolute path"));
    }
    // One open, no symlink at the last component, and every check on that
    // same descriptor: a file swapped after a check is never the one read.
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = opts.open(p).map_err(|e| {
        if e.raw_os_error() == Some(libc::ELOOP) {
            format!("{path}: not a regular file (a symlink)")
        } else {
            format!("{path}: {e}")
        }
    })?;
    let meta = file.metadata().map_err(|e| format!("{path}: {e}"))?;
    if !meta.file_type().is_file() {
        return Err(format!("{path}: not a regular file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no preconditions.
        if meta.uid() != unsafe { libc::geteuid() } {
            return Err(format!("{path}: owned by another user"));
        }
        if meta.mode() & 0o077 != 0 {
            return Err(format!("{path}: readable by others (needs mode 0600)"));
        }
    }
    if meta.len() > FILE_SECRET_MAX {
        return Err(format!("{path}: larger than {FILE_SECRET_MAX} bytes"));
    }
    let mut text = String::new();
    use std::io::Read;
    file.take(FILE_SECRET_MAX + 1).read_to_string(&mut text).map_err(|e| format!("{path}: {e}"))?;
    Ok(text)
}

/// No owner-only check exists here yet (a Windows ACL check is separate
/// work), so a `file:` reference is refused, never read unchecked.
#[cfg(not(unix))]
fn read_owner_only(path: &str) -> Result<String, String> {
    Err(format!(
        "{path}: file references are supported only on Unix (no owner-only check on this system)"
    ))
}

/// Replace `${keychain:…}` and `${env:…}` in env values with their values.
/// `lookup_env` reads the login environment; `lookup_keychain` reads one
/// secret by (service, account). An unresolved reference is an error that
/// names the key and the item, never a value.
pub fn resolve_env_refs(
    env: &mut BTreeMap<String, String>,
    lookup_env: &dyn Fn(&str) -> Option<String>,
    lookup_keychain: &dyn Fn(&str, Option<&str>) -> Result<String, String>,
) -> Result<(), String> {
    for (key, value) in env.iter_mut() {
        if !is_reference(value) {
            continue;
        }
        let mut out = String::new();
        let mut rest = value.as_str();
        while let Some((before, after)) = rest.split_once("${") {
            out.push_str(before);
            let Some((inner, tail)) = after.split_once('}') else {
                out.push_str("${");
                out.push_str(after);
                rest = "";
                break;
            };
            if let Some(var) = inner.strip_prefix("env:") {
                let v = lookup_env(var).ok_or_else(|| {
                    format!("env {key}: ${{env:{var}}} is not set in the login environment")
                })?;
                out.push_str(&v);
            } else if let Some(path) = inner.strip_prefix("file:") {
                let v = file_secret(path).map_err(|e| format!("env {key}: file reference: {e}"))?;
                out.push_str(&v);
            } else if let Some(item) = inner.strip_prefix("keychain:") {
                let (service, account) = match item.split_once('/') {
                    Some((s, a)) => (s, Some(a)),
                    None => (item, None),
                };
                let v = lookup_keychain(service, account)
                    .map_err(|e| format!("env {key}: Keychain item {item:?}: {e}"))?;
                out.push_str(&v);
            } else {
                // `${cwd}`, `${model}`… are expanded elsewhere.
                out.push_str("${");
                out.push_str(inner);
                out.push('}');
            }
            rest = tail;
        }
        out.push_str(rest);
        *value = out;
    }
    Ok(())
}

/// Whether any env value holds a reference that must be resolved.
pub fn has_env_refs(env: &BTreeMap<String, String>) -> bool {
    env.values().any(|v| is_reference(v))
}

/// Whether any env value names a Keychain item, so resolving it reads the
/// secret store.
pub fn has_keychain_refs(env: &BTreeMap<String, String>) -> bool {
    env.values().any(|v| v.contains("${keychain:"))
}

/// The system secret store: `security` on macOS, `secret-tool` elsewhere.
/// The value goes only to the caller; nothing is logged.
pub fn keychain_lookup(service: &str, account: Option<&str>) -> Result<String, String> {
    use wait_timeout::ChildExt;
    let mut cmd = if std::env::consts::OS == "macos" {
        let mut c = std::process::Command::new("/usr/bin/security");
        c.args(["find-generic-password", "-s", service]);
        if let Some(a) = account {
            c.args(["-a", a]);
        }
        // -g (password on stderr, `0x` hex for non-ASCII), not -w (bare hex).
        c.arg("-g");
        c
    } else {
        let mut c = std::process::Command::new("secret-tool");
        c.args(["lookup", "service", service]);
        if let Some(a) = account {
            c.args(["account", a]);
        }
        c
    };
    let macos = std::env::consts::OS == "macos";
    cmd.stdin(std::process::Stdio::null());
    if macos {
        cmd.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::piped());
    } else {
        cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
    }
    let mut child = cmd.spawn().map_err(|e| format!("cannot run the secret store: {e}"))?;
    // The store may ask the person to unlock it.
    crate::daemon::hang_watch::will_block();
    match child.wait_timeout(std::time::Duration::from_secs(30)) {
        Ok(Some(status)) if status.success() => {}
        Ok(Some(_)) => {
            return Err("not found (add it with `cmux harness secret set`)".into());
        }
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err("the secret store did not answer in 30 s".into());
        }
        Err(e) => return Err(e.to_string()),
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if macos {
        let text = String::from_utf8_lossy(&out.stderr);
        return parse_security_password(&text)
            .ok_or_else(|| "the Keychain item is not UTF-8 text".to_owned());
    }
    let mut value = String::from_utf8(out.stdout).map_err(|_| "not UTF-8".to_owned())?;
    while value.ends_with('\n') || value.ends_with('\r') {
        value.pop();
    }
    Ok(value)
}

/// The password in `security find-generic-password -g` output (stderr):
/// `password: "text"` for printable ASCII, `password: 0x<HEX>  "<escaped>"`
/// for anything else (UTF-8 included), `password: ` for an empty one. The
/// `0x` form is the only one decoded, so an ASCII secret that looks like hex
/// stays as it is. (`-w` prints bare hex for non-ASCII and cannot be told
/// apart from such a secret.)
pub fn parse_security_password(stderr: &str) -> Option<String> {
    let line = stderr
        .lines()
        .find_map(|l| l.strip_prefix("password: ").or_else(|| (l == "password:").then_some("")))?;
    if let Some(hex) = line.strip_prefix("0x") {
        let hex = hex.split_whitespace().next().unwrap_or_default();
        if hex.len() % 2 != 0 {
            return None;
        }
        let bytes: Option<Vec<u8>> = hex
            .as_bytes()
            .chunks(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
            .collect();
        return String::from_utf8(bytes?).ok();
    }
    if line.is_empty() {
        return Some(String::new());
    }
    let inner = line.strip_prefix('"')?.strip_suffix('"')?;
    Some(inner.to_owned())
}
