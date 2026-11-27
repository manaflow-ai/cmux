//! What a Chief can reach, carried with a move as names only
//! (plans/cmux-next/chief-migration-DESIGN.md section 6a): the SSH hosts in
//! the source user's `~/.ssh/config`, the tailnet peers, the build-fleet
//! controller and the model route. No key, token or password is read or
//! written: credentials are listed by kind, so the target can say which ones
//! it lacks. `optchat-chief move reach` probes each from the machine it runs
//! on and reports what works there and what does not.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

/// The fleet controller (the `cmux-ci` client's default).
pub const FLEET_CONTROLLER: &str = "http://100.89.225.106:18765";

fn user_home() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(std::path::PathBuf::from)
}

/// `Host` aliases (no wildcards) of an ssh config text, with HostName and User.
pub fn ssh_hosts(config: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut current: Vec<usize> = Vec::new();
    for raw in config.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once(|c: char| c.is_whitespace() || c == '=') {
            Some((k, v)) => (
                k.to_ascii_lowercase(),
                v.trim().trim_start_matches('=').trim(),
            ),
            None => continue,
        };
        match key.as_str() {
            "host" => {
                current.clear();
                for name in value.split_whitespace() {
                    if name.contains(['*', '?', '!']) {
                        continue;
                    }
                    current.push(out.len());
                    out.push(json!({"name": name}));
                }
            }
            "match" => current.clear(),
            "hostname" | "user" => {
                for &i in &current {
                    out[i][key.as_str()] = json!(value);
                }
            }
            _ => {}
        }
    }
    out
}

fn run(program: &str, args: &[&str], limit: Duration) -> Option<String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + limit;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            if !status.success() {
                return None;
            }
            let mut out = String::new();
            use std::io::Read;
            child.stdout.take()?.read_to_string(&mut out).ok()?;
            return Some(out);
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        // Bounded wait for a short probe command.
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The tailnet peers this machine sees (names and online state).
fn tailnet() -> Value {
    // A non-login shell (ssh, launchd) often lacks Homebrew's or the app's bin.
    let found = [
        "tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]
    .into_iter()
    .find_map(|bin| run(bin, &["status", "--json"], Duration::from_secs(8)));
    let Some(text) = found else {
        return json!({"available": false});
    };
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    let name = |p: &Value| {
        p["DNSName"]
            .as_str()
            .map(|d| d.trim_end_matches('.').to_owned())
            .unwrap_or_default()
    };
    let peers: Vec<Value> = v["Peer"]
        .as_object()
        .map(|m| {
            m.values()
                .map(|p| json!({"name": name(p), "online": p["Online"]}))
                .collect()
        })
        .unwrap_or_default();
    json!({"available": true, "self": name(&v["Self"]), "peers": peers})
}

/// What this machine's Chief reaches, by name only.
pub fn collect() -> Value {
    let home = user_home();
    let ssh = home
        .as_ref()
        .and_then(|h| std::fs::read_to_string(h.join(".ssh/config")).ok())
        .map(|t| ssh_hosts(&t))
        .unwrap_or_default();
    let has = |p: &str| home.as_ref().is_some_and(|h| h.join(p).exists());
    let keys: Vec<String> = home
        .as_ref()
        .and_then(|h| std::fs::read_dir(h.join(".ssh")).ok())
        .map(|d| {
            d.filter_map(Result::ok)
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("id_") && !n.ends_with(".pub"))
                .collect()
        })
        .unwrap_or_default();
    let model_route = crate::cli::env("ANTHROPIC_BASE_URL")
        .filter(|u| u.starts_with("http://") || u.starts_with("https://"));
    json!({
        "ssh_hosts": ssh,
        "tailnet": tailnet(),
        "fleet": {"controller": FLEET_CONTROLLER, "client": has(".local/bin/cmux-ci")},
        "model_route": model_route,
        // Kinds only: never a value, never a file's contents.
        "credentials": {
            "ssh_keys": keys,
            "gh_login": has(".config/gh/hosts.yml"),
            "fleet_identity": "tailnet login (no token)",
        },
    })
}

fn ssh_ok(host: &str) -> bool {
    run(
        "ssh",
        &[
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=6",
            "-o",
            "StrictHostKeyChecking=accept-new",
            host,
            "true",
        ],
        Duration::from_secs(12),
    )
    .is_some()
}

fn http_ok(url: &str) -> bool {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(6))
        .build();
    match agent.get(url).call() {
        Ok(_) | Err(ureq::Error::Status(_, _)) => true,
        Err(_) => false,
    }
}

/// Probes the carried reach (`optchat/reach-source.json` of `home`) from
/// this machine.
pub fn probe(home: &Path) -> Result<Value, String> {
    let path = home.join("optchat").join("reach-source.json");
    let text = std::fs::read_to_string(&path).map_err(|e| {
        format!(
            "{}: {e} (this home was not moved in, or before reach)",
            path.display()
        )
    })?;
    let reach: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let names: Vec<String> = reach["ssh_hosts"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|h| h["name"].as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    let handles: Vec<_> = names
        .into_iter()
        .map(|n| std::thread::spawn(move || (n.clone(), ssh_ok(&n))))
        .collect();
    let mut ssh_up = Vec::new();
    let mut ssh_down = Vec::new();
    for h in handles {
        if let Ok((n, ok)) = h.join() {
            if ok { ssh_up.push(n) } else { ssh_down.push(n) }
        }
    }
    let here = tailnet();
    let fleet = reach["fleet"]["controller"]
        .as_str()
        .unwrap_or(FLEET_CONTROLLER)
        .to_owned();
    let fleet_ok = http_ok(&format!("{fleet}/status"));
    let route = reach["model_route"].as_str().map(str::to_owned);
    let route_ok = route.as_deref().map(http_ok);
    let mut blockers = Vec::new();
    if !ssh_down.is_empty() {
        blockers.push(format!(
            "{} SSH hosts do not answer from here: this machine's key is not authorized there, or no route (keys are never copied)",
            ssh_down.len()
        ));
    }
    if here["available"] != true {
        blockers.push("this machine is not on the tailnet (tailscale status failed)".into());
    }
    if !fleet_ok {
        blockers.push(format!(
            "the fleet controller {fleet} does not answer from here"
        ));
    }
    if route_ok == Some(false) {
        blockers.push(format!(
            "the model route {} does not answer from here",
            route.clone().unwrap_or_default()
        ));
    }
    if reach["credentials"]["gh_login"] == true {
        blockers.push("GitHub login: `gh auth login` on this machine (never copied)".into());
    }
    Ok(json!({
        "ssh": {"reachable": ssh_up, "unreachable": ssh_down},
        "tailnet": {"here": here["available"], "self": here["self"]},
        "fleet": {"controller": fleet, "reachable": fleet_ok},
        "model_route": {"url": route, "reachable": route_ok},
        "blockers": blockers,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_config_hosts_without_wildcards_and_without_secrets() {
        let config = "Host *\n  IdentityFile ~/.ssh/id_ed25519\nHost mini cmux-mini\n  HostName 100.1.2.3\n  User lawrence\n  IdentityFile ~/.ssh/secret_key\nHost *.corp\n  User x\nMatch host foo\n  User y\nHost vm\n  HostName=10.0.0.9\n";
        let hosts = ssh_hosts(config);
        assert_eq!(hosts.len(), 3);
        assert_eq!(
            hosts[0],
            json!({"name": "mini", "hostname": "100.1.2.3", "user": "lawrence"})
        );
        assert_eq!(hosts[1]["name"], "cmux-mini");
        assert_eq!(hosts[2], json!({"name": "vm", "hostname": "10.0.0.9"}));
        let text = serde_json::to_string(&hosts).unwrap();
        assert!(!text.contains("secret_key") && !text.contains("IdentityFile"));
    }
}
