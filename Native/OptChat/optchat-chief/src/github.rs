//! A local Chief's GitHub login (plans/cmux-next/chief-github-DESIGN.md
//! section 4): `optchat-chief github status|login|wait|pat|mac|logout|token`.
//!
//! The default is the Mac's own `gh` login: a Chief with no login of its own
//! runs `gh` and `git` as the person does. `login` (the GitHub CLI's device
//! flow) or `pat` gives the Chief its own token, kept in the login keychain
//! on macOS (generic password, service `cmux.chief.github`, account the
//! Chief home's id; written through `security -i` on stdin, so the token is
//! never an argument), else in `$MUX_HOME/optchat/secrets/github.json`
//! (mode 0600, outside any repository). The status (never the token) is
//! `$MUX_HOME/optchat/github.json`.
//!
//! Every turn: the session's launcher directory (first on PATH,
//! session_dir.rs) holds a `gh` shim that reads the token on each call
//! (`chief github token`) and a git credential helper, so a sign-in or a
//! rotate applies at the next command, with no host restart.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The GitHub CLI's OAuth app (public client id; `gh auth login --web`).
pub const CLIENT_ID: &str = "178c6fc778ccc68e1d6a";
/// gh's defaults plus `workflow` (pushes that touch .github/workflows).
pub const SCOPES: &str = "repo read:org gist workflow";
const WEB: &str = "https://github.com";
const API: &str = "https://api.github.com";
const SERVICE: &str = "cmux.chief.github";
const REVOKE_PAGE: &str = "https://github.com/settings/applications";

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn status_path(home: &Path) -> PathBuf {
    home.join("optchat").join("github.json")
}

fn secret_file(home: &Path) -> PathBuf {
    home.join("optchat").join("secrets").join("github.json")
}

/// A token as GitHub makes them (`gho_…`, `ghp_…`, `github_pat_…`, `ghs_…`):
/// the only text that goes into the keychain command line on stdin.
pub fn token_ok(token: &str) -> bool {
    (20..=255).contains(&token.len())
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// Where the Chief's own token lives.
pub trait Store {
    fn get(&self) -> Option<String>;
    fn set(&self, token: &str) -> Result<(), String>;
    fn clear(&self) -> Result<(), String>;
}

/// The macOS login keychain.
pub struct Keychain {
    pub account: String,
}

impl Store for Keychain {
    fn get(&self) -> Option<String> {
        let out = Command::new("/usr/bin/security")
            .args([
                "find-generic-password",
                "-s",
                SERVICE,
                "-a",
                &self.account,
                "-w",
            ])
            .stderr(Stdio::null())
            .output()
            .ok()?;
        let t = String::from_utf8(out.stdout).ok()?.trim().to_owned();
        (out.status.success() && token_ok(&t)).then_some(t)
    }
    fn set(&self, token: &str) -> Result<(), String> {
        if !token_ok(token) {
            return Err("not a GitHub token".into());
        }
        let mut child = Command::new("/usr/bin/security")
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("security: {e}"))?;
        let line = format!(
            "add-generic-password -U -s {SERVICE} -a {} -l \"cmux Chief GitHub\" -w {token}\n",
            self.account
        );
        child
            .stdin
            .take()
            .ok_or("security: no stdin")?
            .write_all(line.as_bytes())
            .map_err(|e| format!("security: {e}"))?;
        let out = child
            .wait_with_output()
            .map_err(|e| format!("security: {e}"))?;
        if out.status.success() && self.get().as_deref() == Some(token) {
            Ok(())
        } else {
            Err("the keychain did not take the token".into())
        }
    }
    fn clear(&self) -> Result<(), String> {
        let _ = Command::new("/usr/bin/security")
            .args([
                "delete-generic-password",
                "-s",
                SERVICE,
                "-a",
                &self.account,
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        Ok(())
    }
}

/// A 0600 file under the Chief home (hosts without a keychain).
pub struct FileStore {
    pub path: PathBuf,
}

impl Store for FileStore {
    fn get(&self) -> Option<String> {
        let v: Value = serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()?;
        v["token"]
            .as_str()
            .filter(|t| token_ok(t))
            .map(str::to_owned)
    }
    fn set(&self, token: &str) -> Result<(), String> {
        if !token_ok(token) {
            return Err("not a GitHub token".into());
        }
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
        let tmp = self.path.with_extension("tmp");
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(json!({ "token": token }).to_string().as_bytes())
            .map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }
    fn clear(&self) -> Result<(), String> {
        match std::fs::remove_file(&self.path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        }
    }
}

/// The store of this Chief home on this machine.
pub fn store(home: &Path) -> Box<dyn Store> {
    if cfg!(target_os = "macos") && Path::new("/usr/bin/security").exists() {
        Box::new(Keychain {
            account: crate::paths::home_id(home),
        })
    } else {
        Box::new(FileStore {
            path: secret_file(home),
        })
    }
}

/// `github-authentication-token-expiration` ("2026-12-01 00:00:00 UTC" or
/// "... +0000") in ms since the epoch.
pub fn expiry_ms(header: &str) -> Option<u64> {
    let mut parts = header.split_whitespace();
    let (date, time, zone) = (parts.next()?, parts.next()?, parts.next()?);
    let offset = match zone {
        "UTC" => "+00:00".to_owned(),
        z if z.len() == 5 => format!("{}:{}", &z[..3], &z[3..]),
        _ => return None,
    };
    chrono::DateTime::parse_from_rfc3339(&format!("{date}T{time}{offset}"))
        .ok()
        .and_then(|t| u64::try_from(t.timestamp_millis()).ok())
}

/// `x-oauth-scopes` as a sorted list (empty for fine-grained tokens).
pub fn scopes_of(header: &str) -> Vec<String> {
    let mut s: Vec<String> = header
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect();
    s.sort();
    s
}

/// The message the Chief posts: the code (one tap copies it) and the page
/// alone on its line (its link preview is the card).
pub fn card(user_code: &str, uri: &str) -> String {
    format!(
        "Sign in to GitHub for this Chief: copy the code `{user_code}`, open the page below and approve.\n{uri}"
    )
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(20))
        .user_agent("cmux-chief")
        .build()
}

/// Who a token is: login, scopes, expiry (GET /user).
fn who_is(token: &str) -> Result<Value, String> {
    match agent()
        .get(&format!("{API}/user"))
        .set("authorization", &format!("Bearer {token}"))
        .set("accept", "application/vnd.github+json")
        .call()
    {
        Ok(r) => {
            let scopes = scopes_of(r.header("x-oauth-scopes").unwrap_or(""));
            let expires = r
                .header("github-authentication-token-expiration")
                .and_then(expiry_ms);
            let body: Value = r.into_json().map_err(|e| e.to_string())?;
            Ok(json!({"login": body["login"], "scopes": scopes, "expires_at": expires}))
        }
        Err(ureq::Error::Status(code, _)) => Err(format!("GitHub refused the token (HTTP {code})")),
        Err(e) => Err(format!("GitHub did not answer: {e}")),
    }
}

fn read_status(home: &Path) -> Value {
    std::fs::read(status_path(home))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({}))
}

fn write_status(home: &Path, v: &Value) -> Result<(), String> {
    let p = status_path(home);
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(&p, format!("{v:#}\n")).map_err(|e| e.to_string())
}

fn keep(home: &Path, kind: &str, token: &str) -> Result<Value, String> {
    let who = who_is(token)?;
    store(home).set(token)?;
    let now = now_ms();
    let v = json!({"kind": kind, "login": who["login"], "scopes": who["scopes"],
        "expires_at": who["expires_at"], "set_at": now, "checked_at": now});
    write_status(home, &v)?;
    Ok(status(home))
}

/// The Mac's own gh login, as `{login, scopes}`, when gh is signed in.
fn mac_login() -> Option<Value> {
    let out = Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let t = String::from_utf8(out.stdout).ok()?.trim().to_owned();
    if !out.status.success() || t.is_empty() {
        return None;
    }
    who_is(&t).ok()
}

/// The status: the Chief's own login, else the Mac's gh login (kind `mac`).
pub fn status(home: &Path) -> Value {
    let mut s = read_status(home);
    let own = store(home).get().is_some();
    if own && s.get("kind").is_some() {
        s["signed_in"] = json!(true);
        s["own"] = json!(true);
    } else {
        let pending = s.get("pending").cloned();
        s = match mac_login() {
            Some(w) => json!({"signed_in": true, "own": false, "kind": "mac",
                "login": w["login"], "scopes": w["scopes"], "expires_at": w["expires_at"]}),
            None => json!({"signed_in": false, "own": false}),
        };
        if let Some(p) = pending {
            s["pending"] = p;
        }
    }
    if s["pending"]["expires_at"]
        .as_u64()
        .is_some_and(|t| t <= now_ms())
    {
        s.as_object_mut().map(|o| o.remove("pending"));
    }
    s
}

/// One device-flow poll: Ok(Some(token)) once approved, Ok(None) while
/// pending (with the next interval), Err when it ended.
fn poll(device_code: &str, interval: &mut u64) -> Result<Option<String>, String> {
    let r = agent()
        .post(&format!("{WEB}/login/oauth/access_token"))
        .set("accept", "application/json")
        .send_form(&[
            ("client_id", CLIENT_ID),
            ("device_code", device_code),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ]);
    let body: Value = match r {
        Ok(r) => r.into_json().map_err(|e| e.to_string())?,
        Err(ureq::Error::Status(_, r)) => r.into_json().unwrap_or(Value::Null),
        Err(_) => return Ok(None),
    };
    if let Some(t) = body["access_token"].as_str() {
        return Ok(Some(t.to_owned()));
    }
    match body["error"].as_str() {
        Some("authorization_pending") | None => Ok(None),
        Some("slow_down") => {
            *interval += 5;
            Ok(None)
        }
        Some("access_denied") => Err("the sign-in was denied on GitHub".into()),
        Some(e) => Err(format!("GitHub ended the sign-in ({e})")),
    }
}

/// `login`: starts the device flow, leaves a detached poller that outlives
/// the turn (it reads the device code on stdin) and returns the card.
fn login(home: &Path) -> Result<Value, String> {
    let r: Value = agent()
        .post(&format!("{WEB}/login/device/code"))
        .set("accept", "application/json")
        .send_form(&[("client_id", CLIENT_ID), ("scope", SCOPES)])
        .map_err(|e| format!("GitHub did not start a device sign-in: {e}"))?
        .into_json()
        .map_err(|e| e.to_string())?;
    let (Some(device), Some(code)) = (r["device_code"].as_str(), r["user_code"].as_str()) else {
        return Err("GitHub's answer has no device code".into());
    };
    let uri = r["verification_uri"]
        .as_str()
        .unwrap_or("https://github.com/login/device");
    let expires_at = now_ms() + r["expires_in"].as_u64().unwrap_or(900) * 1000;
    let interval = r["interval"].as_u64().unwrap_or(5);
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(home.join("optchat").join("github-login.log"))
        .map_err(|e| e.to_string())?;
    use std::os::unix::process::CommandExt;
    let mut child = Command::new(exe)
        .args(["github", "poll", "--mux-home"])
        .arg(home)
        .args([
            "--interval",
            &interval.to_string(),
            "--until",
            &expires_at.to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(log)
        // Its own process group: the turn's end does not stop it.
        .process_group(0)
        .spawn()
        .map_err(|e| format!("starting the poller: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("poller: no stdin")?
        .write_all(device.as_bytes())
        .map_err(|e| e.to_string())?;
    let mut s = read_status(home);
    s["pending"] = json!({"user_code": code, "verification_uri": uri, "expires_at": expires_at, "pid": child.id()});
    s.as_object_mut().map(|o| o.remove("last_error"));
    write_status(home, &s)?;
    let mut out = status(home);
    out["card"] = json!(card(code, uri));
    Ok(out)
}

/// The detached poller (`github poll`): the device code on stdin.
fn poll_loop(home: &Path, mut interval: u64, until: u64) -> Result<Value, String> {
    let mut device = String::new();
    std::io::stdin()
        .read_to_string(&mut device)
        .map_err(|e| e.to_string())?;
    let device = device.trim().to_owned();
    let end = |home: &Path, error: Option<String>| {
        let mut s = read_status(home);
        if let Some(o) = s.as_object_mut() {
            o.remove("pending");
            if let Some(e) = &error {
                o.insert("last_error".into(), json!(e));
            }
        }
        let _ = write_status(home, &s);
    };
    while now_ms() < until {
        std::thread::sleep(Duration::from_secs(interval.max(1)));
        match poll(&device, &mut interval) {
            Ok(Some(token)) => {
                return match keep(home, "device", &token) {
                    Ok(s) => Ok(s),
                    Err(e) => {
                        end(home, Some(e.clone()));
                        Err(e)
                    }
                };
            }
            Ok(None) => {}
            Err(e) => {
                end(home, Some(e.clone()));
                return Err(e);
            }
        }
    }
    end(
        home,
        Some(
            "the sign-in code expired before it was approved; run `chief github login` again"
                .into(),
        ),
    );
    Err("expired".into())
}

fn logout(home: &Path) -> Result<Value, String> {
    let was = read_status(home);
    store(home).clear()?;
    let _ = std::fs::remove_file(status_path(home));
    let mut s = status(home);
    s["note"] = json!(match was["kind"].as_str() {
        Some("device") => format!("Forgotten here; the Chief uses the Mac's gh login again. The token still works until you revoke it at {REVOKE_PAGE} (\"GitHub CLI\")."),
        Some("pat") => "Forgotten here; the Chief uses the Mac's gh login again. Delete the token at https://github.com/settings/personal-access-tokens if nothing else uses it.".to_owned(),
        _ => "The Chief uses the Mac's gh login.".to_owned(),
    });
    Ok(s)
}

fn read_token(source: Option<&str>) -> Result<String, String> {
    let mut text = String::new();
    match source {
        None | Some("-") => {
            std::io::stdin()
                .read_to_string(&mut text)
                .map_err(|e| e.to_string())?;
        }
        Some(file) => text = std::fs::read_to_string(file).map_err(|e| format!("{file}: {e}"))?,
    }
    let t = text.trim().to_owned();
    if token_ok(&t) {
        Ok(t)
    } else {
        Err("that is not one GitHub token".into())
    }
}

/// One line for people (the default output; `--json` prints the object).
pub fn describe(s: &Value) -> String {
    let mut line = if s["signed_in"] == json!(true) {
        let scopes = s["scopes"].as_array().map_or(String::new(), |a| {
            a.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        });
        let exp = s["expires_at"].as_u64().map_or(String::new(), |t| {
            chrono::DateTime::from_timestamp_millis(t as i64).map_or(String::new(), |d| {
                format!(", expires {}", d.format("%Y-%m-%d"))
            })
        });
        format!(
            "signed in as {} ({}{}; {}{exp})",
            s["login"].as_str().unwrap_or("?"),
            s["kind"].as_str().unwrap_or("?"),
            if s["own"] == json!(true) {
                ", this Chief's own"
            } else {
                ", the Mac's gh"
            },
            if scopes.is_empty() {
                "fine-grained".to_owned()
            } else {
                scopes
            }
        )
    } else {
        "not signed in to GitHub (chief github login)".to_owned()
    };
    if let Some(p) = s.get("pending").filter(|p| p.is_object()) {
        line.push_str(&format!(
            "\nwaiting for approval: code {} at {}",
            p["user_code"].as_str().unwrap_or("?"),
            p["verification_uri"].as_str().unwrap_or("?")
        ));
    }
    if let Some(e) = s["last_error"].as_str() {
        line.push_str(&format!("\nlast sign-in: {e}"));
    }
    if let Some(c) = s["card"].as_str() {
        line = format!(
            "{c}\n\n(post the two lines above as your reply; the poller keeps going after your turn)\n{line}"
        );
    }
    if let Some(n) = s["note"].as_str() {
        line.push_str(&format!("\n{n}"));
    }
    line
}

pub const USAGE: &str = "optchat-chief github status | login | wait [SECONDS] | pat FILE|- | mac | logout | token [--json] [--mux-home DIR]";

/// `optchat-chief github ...`.
pub fn run(flags: &crate::cli::Flags, home: &Path, as_json: bool) -> Result<String, String> {
    let verb = flags.words.get(1).map_or("status", String::as_str);
    let s = match verb {
        "status" => status(home),
        "login" => login(home)?,
        "wait" => {
            let limit = flags
                .words
                .get(2)
                .and_then(|w| w.parse().ok())
                .unwrap_or(600u64);
            let end = now_ms() + limit * 1000;
            loop {
                let s = status(home);
                if s["own"] == json!(true) || s.get("pending").is_none() || now_ms() >= end {
                    break s;
                }
                std::thread::sleep(Duration::from_secs(3));
            }
        }
        "pat" => keep(
            home,
            "pat",
            &read_token(flags.words.get(2).map(String::as_str))?,
        )?,
        "mac" => {
            // The Mac's own login: no copy of its own.
            store(home).clear()?;
            let _ = std::fs::remove_file(status_path(home));
            status(home)
        }
        "logout" => logout(home)?,
        // The shim's call: the Chief's own token, or nothing (exit 1).
        "token" => {
            return store(home)
                .get()
                .ok_or_else(|| "no token of this Chief's own".to_owned());
        }
        "poll" => {
            let interval = flags
                .value("interval")
                .and_then(|v| v.parse().ok())
                .unwrap_or(5);
            let until = flags
                .value("until")
                .and_then(|v| v.parse().ok())
                .unwrap_or(now_ms() + 900_000);
            poll_loop(home, interval, until)?
        }
        _ => return Err(USAGE.into()),
    };
    Ok(if as_json { s.to_string() } else { describe(&s) })
}

/// The `gh` shim in the turn's launcher directory (session_dir.rs): the
/// Chief's own token when it has one, else the person's gh as it is.
pub const GH_SHIM: &str = r#"#!/bin/sh
# optchat-chief: gh with this Chief's own GitHub login when it has one
# (github.rs GH_SHIM; `chief github status`), else the user's gh as it is.
self_dir=$(cd "$(dirname "$0")" && pwd -P)
PATH=$(printf '%s' "$PATH" | tr ':' '
' | while IFS= read -r d; do
  [ -n "$d" ] && [ "$(cd "$d" 2>/dev/null && pwd -P)" != "$self_dir" ] && printf '%s:' "$d"
done)
PATH=${PATH%:}
export PATH
if [ -z "${GH_TOKEN:-}" ] && t=$("$self_dir/chief" github token 2>/dev/null) && [ -n "$t" ]; then
  GH_TOKEN=$t
  export GH_TOKEN
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "gh: not found on PATH (after the Chief's own bin)" >&2
  exit 127
fi
exec gh "$@"
"#;

/// The git credential helper beside it: the Chief's own token for
/// github.com, else gh's own helper (the person's login).
pub const GIT_CREDENTIAL: &str = r#"#!/bin/sh
# optchat-chief: git credentials for https://github.com (github.rs GIT_CREDENTIAL).
self_dir=$(cd "$(dirname "$0")" && pwd -P)
exec "$self_dir/gh" auth git-credential "$@"
"#;

/// The turn env that makes git ask the helper above for github.com
/// (GIT_CONFIG_* is git's command-line config: the helper list is reset
/// first, so the person's own helper does not answer before it).
pub fn git_env(bin: &Path) -> Vec<(String, String)> {
    let key = "credential.https://github.com.helper";
    vec![
        ("GIT_CONFIG_COUNT".into(), "2".into()),
        ("GIT_CONFIG_KEY_0".into(), key.into()),
        ("GIT_CONFIG_VALUE_0".into(), String::new()),
        ("GIT_CONFIG_KEY_1".into(), key.into()),
        (
            "GIT_CONFIG_VALUE_1".into(),
            bin.join("git-credential-chief").display().to_string(),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_github_headers() {
        assert_eq!(
            expiry_ms("2026-12-01 00:00:00 UTC"),
            Some(1_796_083_200_000)
        );
        assert_eq!(
            expiry_ms("2026-12-01 01:00:00 +0100"),
            Some(1_796_083_200_000)
        );
        assert_eq!(expiry_ms("soon"), None);
        assert_eq!(
            scopes_of("workflow, repo,gist , read:org"),
            ["gist", "read:org", "repo", "workflow"]
        );
        assert!(scopes_of("").is_empty());
    }

    #[test]
    fn card_has_the_code_and_the_page_on_its_own_line() {
        let c = card("ABCD-1234", "https://github.com/login/device");
        assert!(c.contains("`ABCD-1234`"));
        assert!(c.ends_with("\nhttps://github.com/login/device"));
    }

    #[test]
    fn only_token_shaped_text_is_kept() {
        assert!(token_ok("gho_0123456789abcdefABCDEF0123"));
        assert!(token_ok("github_pat_11ABCDEFG0123456789_abcdefghijklmnop"));
        assert!(!token_ok("gho_short"));
        assert!(!token_ok("gho_0123456789abcdef -w evil"));
        assert!(!token_ok("gho_0123456789abcdef\"\nadd-generic-password"));
    }

    #[test]
    fn file_store_is_private_and_round_trips() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("chief-github-{}", std::process::id()));
        let s = FileStore {
            path: dir.join("secrets").join("github.json"),
        };
        let t = "ghp_0123456789abcdefABCDEF0123456789";
        s.set(t).unwrap();
        assert_eq!(s.get().as_deref(), Some(t));
        assert_eq!(
            std::fs::metadata(&s.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(s.set("not a token").is_err());
        s.clear().unwrap();
        assert_eq!(s.get(), None);
        s.clear().unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn describe_names_who_and_whose() {
        let own = json!({"signed_in": true, "own": true, "kind": "device", "login": "octo",
            "scopes": ["repo", "workflow"], "expires_at": null});
        assert_eq!(
            describe(&own),
            "signed in as octo (device, this Chief's own; repo workflow)"
        );
        let mac = json!({"signed_in": true, "own": false, "kind": "mac", "login": "octo", "scopes": [],
            "expires_at": 1_796_083_200_000u64});
        assert_eq!(
            describe(&mac),
            "signed in as octo (mac, the Mac's gh; fine-grained, expires 2026-12-01)"
        );
        let none = json!({"signed_in": false, "pending": {"user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device"}});
        assert!(describe(&none).contains("waiting for approval: code ABCD-1234"));
    }

    #[test]
    fn shims_drop_their_own_dir_and_read_the_chiefs_token() {
        assert!(GH_SHIM.contains("\"$self_dir/chief\" github token"));
        assert!(GH_SHIM.contains("exec gh \"$@\""));
        assert!(GIT_CREDENTIAL.contains("auth git-credential"));
        let env = git_env(Path::new("/h/optchat/bin"));
        assert_eq!(env[2], ("GIT_CONFIG_VALUE_0".into(), String::new()));
        assert_eq!(env[4].1, "/h/optchat/bin/git-credential-chief");
    }
}
