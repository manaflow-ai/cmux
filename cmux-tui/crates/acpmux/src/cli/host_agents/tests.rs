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
