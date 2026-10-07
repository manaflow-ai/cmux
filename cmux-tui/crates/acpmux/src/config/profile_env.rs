//! Env references in a harness profile: `${keychain:service[/account]}` and
//! `${env:VAR}`, resolved only when a harness starts. Part of
//! `config/profiles.rs`.

use std::collections::BTreeMap;

pub(super) fn is_reference(value: &str) -> bool {
    value.contains("${keychain:") || value.contains("${env:")
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
        while let Some(start) = rest.find("${") {
            out.push_str(&rest[..start]);
            let after = &rest[start + 2..];
            let Some(end) = after.find('}') else {
                out.push_str(&rest[start..]);
                rest = "";
                break;
            };
            let inner = &after[..end];
            if let Some(var) = inner.strip_prefix("env:") {
                let v = lookup_env(var).ok_or_else(|| {
                    format!("env {key}: ${{env:{var}}} is not set in the login environment")
                })?;
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
                out.push_str(&rest[start..start + 2 + end + 1]);
            }
            rest = &after[end + 1..];
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
        let bytes: Option<Vec<u8>> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok())
            .collect();
        return String::from_utf8(bytes?).ok();
    }
    if line.is_empty() {
        return Some(String::new());
    }
    let inner = line.strip_prefix('"')?.strip_suffix('"')?;
    Some(inner.to_owned())
}

#[cfg(test)]
mod security_output_tests {
    use super::parse_security_password;

    #[test]
    fn reads_every_form_security_prints() {
        let p = |s: &str| parse_security_password(s);
        assert_eq!(p("password: \"plainvalue123\"\n").as_deref(), Some("plainvalue123"));
        assert_eq!(p("password: \"dq\"inside\"x\"\n").as_deref(), Some("dq\"inside\"x"));
        // Printed by security for `unicode-é-日本` (UTF-8, not printable ASCII).
        let hex = "password: 0x756E69636F64652DC3A92DE697A5E69CAC  \"unicode-\\303\\251-\\346\\227\\245\\346\\234\\254\"\n";
        assert_eq!(p(hex).as_deref(), Some("unicode-é-日本"));
        // An ASCII secret made of hex digits is not decoded.
        assert_eq!(p("password: \"deadbeef\"\n").as_deref(), Some("deadbeef"));
        assert_eq!(p("password: \n").as_deref(), Some(""));
        assert_eq!(p("keychain: \"/x\"\n"), None);
    }
}
