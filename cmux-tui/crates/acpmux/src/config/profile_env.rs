//! Environment-reference helpers for harness profiles.

use std::collections::BTreeMap;

fn is_reference(value: &str) -> bool {
    value.contains("${keychain:") || value.contains("${env:")
}

/// JSON with `//` and `/* */` comments, comments removed (strings kept).
fn strip_json_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    let mut in_string = false;
    while let Some(c) = chars.next() {
        if in_string {
            out.push(c);
            if c == '\\' {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        match (c, chars.peek()) {
            ('"', _) => {
                in_string = true;
                out.push(c);
            }
            ('/', Some('/')) => {
                for n in chars.by_ref() {
                    if n == '\n' {
                        out.push('\n');
                        break;
                    }
                }
            }
            ('/', Some('*')) => {
                chars.next();
                let mut prev = ' ';
                for n in chars.by_ref() {
                    if prev == '*' && n == '/' {
                        break;
                    }
                    prev = n;
                }
            }
            _ => out.push(c),
        }
    }
    out
}

// ------------------------------------------------------- env references

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
        c.arg("-w");
        c
    } else {
        let mut c = std::process::Command::new("secret-tool");
        c.args(["lookup", "service", service]);
        if let Some(a) = account {
            c.args(["account", a]);
        }
        c
    };
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
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
    let mut value = String::from_utf8(out.stdout).map_err(|_| "not UTF-8".to_owned())?;
    while value.ends_with('\n') || value.ends_with('\r') {
        value.pop();
    }
    Ok(value)
}
