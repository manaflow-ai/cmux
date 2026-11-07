//! `acpmux machine agents MACHINE`: whether Claude Code and Codex are installed and signed in on
//! a machine this one added, with what can be offered for each (HQ#7442 row 1). Nothing installs
//! or signs in on its own: each offer is a command the person starts (a button in the app, or
//! this command with a flag).
//!
//! - `--install ID` runs the machine's own `acpmux harness install ID` (the vendor's official
//!   installer) over ssh and passes its step lines through.
//! - `--login ID` runs the machine's `acpmux harness login ID` over `ssh -t`, in this terminal, so a
//!   cmux terminal tab that runs `acpmux machine agents NAME --login ID` signs the machine in with
//!   no other terminal and no ssh typed by hand. Codex's sign-in answers its browser on the
//!   machine's localhost:1455, so that port is forwarded back to this one.
//!
//! Enroll's and doctor's `agents` step (`step`) reports the same, as a warning at worst: the
//! machine works for sessions with no agent signed in on it.

use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::cli::hosts::{self, DAEMON_BIN, REMOTE_HOME, Remote};
use anyhow::{Result, anyhow, bail};
use serde_json::{Map, Value, json};
use std::process::{Command, Stdio};

/// The agents this checks: id, display name, the vendor's install page.
const AGENTS: [(&str, &str, &str); 2] = [
    ("claude", "Claude Code", "https://docs.anthropic.com/en/docs/claude-code/setup"),
    ("codex", "Codex", "https://developers.openai.com/codex/cli"),
];

/// The port Codex's browser sign-in answers on, on the machine that runs `codex login`.
const CODEX_LOGIN_PORT: u16 = 1455;

/// Finds each agent on the machine (PATH, else the native installer's `~/.local/bin`, else
/// cmux's managed Codex) and asks whether it is signed in: `claude auth status` (its JSON's
/// `loggedIn`, as the app's Claude plan read; it can exit 0 signed out, so an exit 0 with no
/// `loggedIn` is unknown) and `codex login status` (exit 0, or Codex's own "Not logged in"). Each check is
/// bounded where the machine has `timeout`. One `agent\tID\tPATH\tSTATUS` line per agent:
/// STATUS 0 signed in, 1 signed out, anything else unknown, empty when not installed.
/// cmux's managed Codex lives in the machine's acpmux home, [`REMOTE_HOME`].
fn probe_script() -> String {
    format!(
        r#"printf 'os\t%s\n' "$(uname -s)"; t=; command -v timeout >/dev/null 2>&1 && t="timeout 20"; for a in claude codex; do p=$(command -v "$a" 2>/dev/null); for c in "$HOME/.local/bin/$a" {REMOTE_HOME}/codex-runtime/current/"$a"; do [ -z "$p" ] && [ -x "$c" ] && p=$c; done; s=; if [ -n "$p" ]; then case $a in claude) o=$($t "$p" auth status </dev/null 2>/dev/null); s=$?; case $o in *'"loggedIn":true'*|*'"loggedIn": true'*) s=0 ;; *'"loggedIn":false'*|*'"loggedIn": false'*) s=1 ;; *) [ "$s" -eq 0 ] && s=9 ;; esac ;; codex) o=$($t "$p" login status </dev/null 2>&1); s=$?; if [ "$s" -ne 0 ]; then case $o in *"ot logged in"*) s=1 ;; *) s=9 ;; esac; fi ;; esac; fi; printf 'agent\t%s\t%s\t%s\n' "$a" "$p" "$s"; done"#
    )
}

/// One agent on the machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Agent {
    pub id: String,
    pub path: Option<String>,
    /// None when the check could not tell (or the agent is not installed).
    pub signed_in: Option<bool>,
}

/// What [`probe_script`] found: the machine's kernel (`uname -s`) and its agents.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Found {
    pub os: String,
    pub agents: Vec<Agent>,
}

pub(crate) fn parse(stdout: &str) -> Found {
    let mut found = Found::default();
    for line in stdout.lines() {
        if let Some(os) = line.strip_prefix("os\t") {
            found.os = os.trim().to_owned();
            continue;
        }
        let mut parts = line.strip_prefix("agent\t").unwrap_or_default().split('\t');
        let (Some(id), path, status) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        if !AGENTS.iter().any(|(known, ..)| *known == id) {
            continue;
        }
        let path = path.map(str::trim).filter(|p| p.starts_with('/')).map(str::to_owned);
        let signed_in = match (path.is_some(), status.map(str::trim)) {
            (true, Some("0")) => Some(true),
            (true, Some("1")) => Some(false),
            _ => None,
        };
        found.agents.push(Agent { id: id.to_owned(), path, signed_in });
    }
    found
}

pub(crate) fn probe(r: &dyn Remote) -> Result<Found> {
    let out = r.exec(&probe_script(), None)?;
    if !out.ok {
        bail!("ssh {} failed: {}", r.host(), out.stderr.trim());
    }
    Ok(parse(&out.stdout))
}

/// Whether `acpmux harness install ID` can install it on a machine with this kernel: Claude
/// Code's installer runs on macOS and Linux; the managed Codex release is macOS only.
fn installable(id: &str, os: &str) -> bool {
    match id {
        "claude" => matches!(os, "Darwin" | "Linux"),
        "codex" => os == "Darwin",
        _ => false,
    }
}

/// One agent's JSON: its state and the offers for it (`install`, `login`: commands this machine
/// runs, each only when the person starts it; `installPage` when acpmux cannot install it there).
pub(crate) fn agent_json(machine: &str, os: &str, a: &Agent) -> Value {
    let (_, name, page) = AGENTS.iter().find(|(id, ..)| *id == a.id).copied().unwrap_or_default();
    let mut v = Map::new();
    v.insert("id".into(), json!(a.id));
    v.insert("name".into(), json!(name));
    v.insert("installed".into(), json!(a.path.is_some()));
    v.insert("path".into(), json!(a.path));
    v.insert("signedIn".into(), json!(a.signed_in));
    let machine = crate::harness_health::channel::quote(machine);
    if a.path.is_none() {
        if installable(&a.id, os) {
            let cmd = format!("acpmux machine agents {machine} --install {}", a.id);
            v.insert("install".into(), json!(cmd));
        } else {
            v.insert("installPage".into(), json!(page));
        }
    } else if a.signed_in != Some(true) {
        let cmd = format!("acpmux machine agents {machine} --login {}", a.id);
        v.insert("login".into(), json!(cmd));
    }
    Value::Object(v)
}

/// One string field of an agent's JSON.
fn field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

/// Enroll's and doctor's `agents` step: ok when one agent is ready there, else a warning whose
/// fix names the first offer. `data.agents` lists every agent with its offers.
pub(crate) fn step(r: &dyn Remote, machine: &str) -> StepResult {
    let found = match probe(r) {
        Ok(found) => found,
        Err(e) => {
            return StepResult::new(
                Step::Agents,
                StepState::Warn,
                format!("could not check the agents: {e:#}"),
            )
            .with_fix("Check again.");
        }
    };
    step_of(machine, &found)
}

fn step_of(machine: &str, found: &Found) -> StepResult {
    let agents: Vec<Value> =
        found.agents.iter().map(|a| agent_json(machine, &found.os, a)).collect();
    let words: Vec<String> = found
        .agents
        .iter()
        .zip(&agents)
        .map(|(a, v)| {
            let name = field(v, "name").unwrap_or(&a.id);
            match (a.path.is_some(), a.signed_in) {
                (false, _) => format!("{name} not installed"),
                (true, Some(true)) => format!("{name} signed in"),
                (true, Some(false)) => format!("{name} not signed in"),
                (true, None) => format!("{name} installed (sign-in unknown)"),
            }
        })
        .collect();
    let ready = found.agents.iter().any(|a| a.path.is_some() && a.signed_in == Some(true));
    let mut result = StepResult::new(
        Step::Agents,
        if ready { StepState::Ok } else { StepState::Warn },
        words.join("; "),
    );
    if !ready {
        let offer = agents.iter().find_map(|v| {
            let name = field(v, "name")?;
            if let Some(cmd) = field(v, "login") {
                return Some(format!("Sign in to {name} there: `{cmd}`."));
            }
            field(v, "install").map(|cmd| format!("Install {name} there: `{cmd}`."))
        });
        result = result.with_fix(
            offer.unwrap_or_else(|| "Install Claude Code or Codex on the machine.".into()),
        );
    }
    result.data = Some(json!({"agents": agents}));
    result
}

fn known(id: &str) -> Result<()> {
    if AGENTS.iter().any(|(known, ..)| *known == id) {
        return Ok(());
    }
    let ids = AGENTS.iter().map(|(id, ..)| *id).collect::<Vec<_>>().join(", ");
    bail!("acpmux machine agents knows {ids}; `{id}` is not one of them")
}

/// `ssh -t [-L 1455:localhost:1455] … HOST 'acpmux harness login ID'`: the machine's sign-in in
/// this terminal.
pub(crate) fn login_argv(host: &str, id: &str) -> Result<Vec<String>> {
    let mut argv = vec!["-t".to_owned()];
    if id == "codex" {
        let port = CODEX_LOGIN_PORT;
        // Without the forward the browser sign-in cannot finish, so ssh stops rather than go on.
        argv.extend([
            "-o".to_owned(),
            "ExitOnForwardFailure=yes".to_owned(),
            "-L".to_owned(),
            format!("{port}:localhost:{port}"),
        ]);
    }
    argv.extend(hosts::ssh_argv(host, &format!("{DAEMON_BIN} harness login {id}"))?);
    Ok(argv)
}

/// `acpmux machine agents MACHINE [--install ID | --login ID]`, MACHINE's ssh host being `host`.
pub(crate) fn run(
    machine: &str,
    host: &str,
    install: Option<String>,
    login: Option<String>,
    json_out: bool,
) -> Result<()> {
    let remote = hosts::SshRemote(host);
    if let Some(id) = install.as_deref() {
        known(id)?;
        // The machine's own installer; its step lines come straight through.
        let out = Command::new("ssh")
            .args(hosts::ssh_argv(host, &format!("{DAEMON_BIN} --json harness install {id}"))?)
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::piped())
            .output()?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            if err.contains("unrecognized subcommand") || err.contains("unexpected argument") {
                bail!(
                    "{machine}'s acpmux cannot install agents yet: `acpmux machine update {machine}` first"
                );
            }
            bail!("installing {id} on {machine} failed: {}", err.trim());
        }
    } else if let Some(id) = login.as_deref() {
        known(id)?;
        let status = Command::new("ssh").args(login_argv(host, id)?).status()?;
        if !status.success() {
            return Err(anyhow!("signing in to {id} on {machine} ended with {status}"));
        }
    }
    let found = probe(&remote)?;
    let agents: Vec<Value> =
        found.agents.iter().map(|a| agent_json(machine, &found.os, a)).collect();
    if json_out {
        println!("{}", json!({"machine": machine, "host": host, "agents": agents}));
    } else {
        let step = step_of(machine, &found);
        println!("{machine}: {}", step.detail);
        if let Some(fix) = step.fix {
            println!("  {fix}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LINUX: &str =
        "os\tLinux\nagent\tclaude\t/home/leo/.local/bin/claude\t1\nagent\tcodex\t\t\n";

    #[test]
    fn the_probe_lines_read_back() {
        let found = parse(LINUX);
        assert_eq!(found.os, "Linux");
        assert_eq!(
            found.agents,
            vec![
                Agent {
                    id: "claude".into(),
                    path: Some("/home/leo/.local/bin/claude".into()),
                    signed_in: Some(false)
                },
                Agent { id: "codex".into(), path: None, signed_in: None },
            ]
        );
        let unknown = parse("agent\tcodex\t/usr/bin/codex\t9\nagent\tother\t/x\t0\n");
        assert_eq!(unknown.agents.len(), 1);
        assert_eq!(unknown.agents[0].signed_in, None);
    }

    #[test]
    fn offers_follow_the_state_and_never_install_codex_off_macos() {
        let found = parse(LINUX);
        let claude = agent_json("hb", "Linux", &found.agents[0]);
        assert_eq!(claude["login"], "acpmux machine agents hb --login claude");
        assert!(claude.get("install").is_none());
        let codex = agent_json("hb", "Linux", &found.agents[1]);
        assert!(codex.get("install").is_none() && codex.get("login").is_none());
        assert_eq!(codex["installPage"], "https://developers.openai.com/codex/cli");
        let mac_codex = agent_json("mini", "Darwin", &found.agents[1]);
        assert_eq!(mac_codex["install"], "acpmux machine agents mini --install codex");
        let ready = Agent { id: "claude".into(), path: Some("/c".into()), signed_in: Some(true) };
        let v = agent_json("hb", "Linux", &ready);
        assert!(v.get("login").is_none() && v.get("install").is_none());
    }

    #[test]
    fn the_step_warns_with_the_first_offer_and_is_ok_once_one_agent_is_ready() {
        let step = step_of("hb", &parse(LINUX));
        assert_eq!(step.state, StepState::Warn);
        assert_eq!(step.detail, "Claude Code not signed in; Codex not installed");
        assert_eq!(
            step.fix.as_deref(),
            Some("Sign in to Claude Code there: `acpmux machine agents hb --login claude`.")
        );
        assert_eq!(step.data.as_ref().unwrap()["agents"].as_array().unwrap().len(), 2);
        assert!(step.healthy());
        let ok = step_of("hb", &parse("os\tLinux\nagent\tclaude\t/c\t0\nagent\tcodex\t\t\n"));
        assert_eq!(ok.state, StepState::Ok);
        assert!(ok.fix.is_none());
        let none = step_of("hb", &parse("os\tLinux\nagent\tclaude\t\t\nagent\tcodex\t\t\n"));
        assert_eq!(
            none.fix.as_deref(),
            Some("Install Claude Code there: `acpmux machine agents hb --install claude`.")
        );
    }

    #[test]
    fn codex_login_forwards_its_callback_port_and_claude_does_not() {
        let codex = login_argv("leo@box", "codex").unwrap();
        assert_eq!(
            &codex[..5],
            ["-t", "-o", "ExitOnForwardFailure=yes", "-L", "1455:localhost:1455"]
        );
        assert!(codex.last().unwrap().contains("~/.local/bin/acpmux harness login codex"));
        let claude = login_argv("leo@box", "claude").unwrap();
        assert_eq!(claude[0], "-t");
        assert!(!claude.iter().any(|a| a == "-L"));
        assert!(login_argv("-oProxyCommand=x", "claude").is_err());
        assert!(known("gemini").is_err());
    }

    #[test]
    fn the_probe_runs_under_sh_and_reports_each_agent() {
        // No agents on PATH and an empty home: both lines say "not installed".
        let home = tempfile::tempdir().unwrap();
        let out = Command::new("/bin/sh")
            .arg("-c")
            .arg(probe_script())
            .env("HOME", home.path())
            .env("PATH", "/usr/bin:/bin")
            .output()
            .unwrap();
        let found = parse(&String::from_utf8_lossy(&out.stdout));
        assert!(!found.os.is_empty());
        let ids: Vec<&str> = found.agents.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["claude", "codex"]);
        // A fake signed-in claude in ~/.local/bin is found off PATH.
        let bin = home.path().join(".local/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let fake = |logged_in: bool| {
            format!(
                "#!/bin/sh\n[ \"$1 $2\" = 'auth status' ] && printf '{{\"loggedIn\":{logged_in}}}\\n'\n"
            )
        };
        std::fs::write(bin.join("claude"), fake(true)).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(bin.join("claude"), std::fs::Permissions::from_mode(0o755))
                .unwrap();
        }
        let out = Command::new("/bin/sh")
            .arg("-c")
            .arg(probe_script())
            .env("HOME", home.path())
            .env("PATH", "/usr/bin:/bin")
            .output()
            .unwrap();
        let found = parse(&String::from_utf8_lossy(&out.stdout));
        assert_eq!(found.agents[0].signed_in, Some(true), "{found:?}");
        // `claude auth status` can exit 0 signed out: its JSON's loggedIn decides.
        std::fs::write(bin.join("claude"), fake(false)).unwrap();
        let out = Command::new("/bin/sh")
            .arg("-c")
            .arg(probe_script())
            .env("HOME", home.path())
            .env("PATH", "/usr/bin:/bin")
            .output()
            .unwrap();
        let found = parse(&String::from_utf8_lossy(&out.stdout));
        assert_eq!(found.agents[0].signed_in, Some(false), "{found:?}");
    }
}
