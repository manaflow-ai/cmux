use super::*;

const LINUX: &str = "os\tLinux\nagent\tclaude\t/home/leo/.local/bin/claude\t1\nagent\tcodex\t\t\n";

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
fn offers_follow_the_state_and_install_codex_on_linux() {
    let found = parse(LINUX);
    let claude = agent_json("hb", "Linux", &found.agents[0]);
    assert_eq!(claude["login"], "acpmux machine agents hb --login claude");
    assert!(claude.get("install").is_none());
    let codex = agent_json("hb", "Linux", &found.agents[1]);
    assert_eq!(codex["install"], "acpmux machine agents hb --install codex");
    assert_eq!(codex["next"], "acpmux machine agents hb --install codex");
    let mac_codex = agent_json("mini", "Darwin", &found.agents[1]);
    assert_eq!(mac_codex["install"], "acpmux machine agents mini --install codex");
    let ready = Agent { id: "claude".into(), path: Some("/c".into()), signed_in: Some(true) };
    let v = agent_json("hb", "Linux", &ready);
    assert!(v.get("login").is_none() && v.get("install").is_none());
}

#[test]
fn local_rows_offer_harness_actions_without_mutating_state() {
    let missing = Agent { id: "claude".into(), path: None, signed_in: None };
    let row = agent_json_for("this machine", "Linux", &missing, true);
    assert_eq!(row["installed"], false);
    assert_eq!(row["signedIn"], Value::Null);
    assert_eq!(row["next"], "acpmux harness install claude");
    let signed_out = Agent {
        id: "claude".into(),
        path: Some("/home/user/.local/bin/claude".into()),
        signed_in: Some(false),
    };
    let row = agent_json_for("this machine", "Linux", &signed_out, true);
    assert_eq!(row["next"], "acpmux harness login claude");
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
fn enroll_installs_each_missing_linux_agent_and_times_the_rows() {
    let found = parse("os\tLinux\nagent\tclaude\t\t\nagent\tcodex\t\t\n");
    let mut calls = Vec::new();
    let mut rows = Vec::new();
    install_missing_with(
        &found,
        "ubuntu",
        |id| {
            calls.push(id.to_owned());
            Ok(())
        },
        &mut |row| rows.push(row.clone()),
    );
    assert_eq!(calls, ["claude", "codex"]);
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|row| row.step == Step::Agents));
    assert!(rows.iter().all(|row| row.state == StepState::Fixed));
    assert!(rows[0].detail.starts_with("installed Claude Code in "));
    assert!(rows[0].detail.ends_with('s'));
    assert!(rows[1].detail.starts_with("installed Codex in "));
}

#[test]
fn enroll_skips_installed_agents_and_names_a_failed_install() {
    let found = parse("os\tLinux\nagent\tclaude\t/home/u/.local/bin/claude\t1\nagent\tcodex\t\t\n");
    let mut calls = Vec::new();
    let mut rows = Vec::new();
    install_missing_with(
        &found,
        "ubuntu",
        |id| {
            calls.push(id.to_owned());
            anyhow::bail!("installer unavailable")
        },
        &mut |row| rows.push(row.clone()),
    );
    assert_eq!(calls, ["codex"]);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].state, StepState::Warn);
    assert!(rows[0].detail.contains("Codex install failed after "));
    assert_eq!(rows[0].fix.as_deref(), Some("Run `acpmux machine agents ubuntu --install codex`."));
}

#[test]
fn codex_login_forwards_its_callback_port_and_claude_does_not() {
    let codex = login_argv("leo@box", "codex").unwrap();
    assert_eq!(&codex[..5], ["-t", "-o", "ExitOnForwardFailure=yes", "-L", "1455:localhost:1455"]);
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
