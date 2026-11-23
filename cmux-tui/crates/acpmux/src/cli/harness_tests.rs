use super::*;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn temp(name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-harness-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

fn options(env: &'static [(&'static str, &'static str)]) -> DoctorOptions {
    DoctorOptions {
        folder: None,
        prompt: true,
        timeout: Duration::from_secs(30),
        lookup_env: Box::new(move |var| {
            env.iter().find(|(k, _)| *k == var).map(|(_, v)| (*v).to_owned())
        }),
        lookup_keychain: Box::new(|_, _| Err("not found".into())),
        extra_env: Default::default(),
    }
}

fn step<'a>(report: &'a DoctorReport, name: &str) -> &'a Step {
    report
        .steps
        .iter()
        .find(|s| s.step == name)
        .unwrap_or_else(|| panic!("no step {name}: {report:?}"))
}

/// A folder `repo` with `.cmux/harnesses/fakefolder.toml` (the fake agent),
/// and a config whose trust and enable records live in the scratch root.
fn folder_fixture(name: &str) -> (PathBuf, Config) {
    use std::os::unix::fs::PermissionsExt;
    let root = std::fs::canonicalize(temp(name)).unwrap();
    let folder = root.join("repo");
    let dir = folder_profiles::profile_dir(&folder);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    let path = dir.join("fakefolder.toml");
    let text =
        format!("schema = 1\nid = \"fakefolder\"\ncommand = \"python3\"\nargs = [{FAKE:?}]\n");
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let gate = folder_profiles::FolderGate {
        enable_record: root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: crate::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
            cmux_worktrees: None,
            peer_scratch: None,
        },
    };
    (folder, Config { folder_gate: Some(gate), ..Default::default() })
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_checks_a_folder_profile_only_when_enabled_and_inside_its_folder() {
    let (folder, cfg) = folder_fixture("doctor-folder");
    let gate = cfg.folder_gate.clone().unwrap();
    let mut opts = options(&[]);
    opts.folder = Some(folder.join("sub"));
    let next = || {
        let fp = folder_profiles::load_one(&cfg, &gate, &folder, "fakefolder").unwrap();
        super::super::harness_folder::next_step(&fp)
    };

    // Not trusted: the profile step fails with the exact next step.
    let report = doctor(&cfg, "fakefolder", &opts).await;
    let s = step(&report, "profile");
    assert_eq!(s.status, StepStatus::Fail, "{}", report.text());
    assert!(s.fix.as_deref().unwrap_or("").contains("answer the Trust question"), "{s:?}");
    assert_eq!(s.fix, next(), "{}", report.text());

    // Trusted, not enabled: the fix is the enable command.
    crate::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let report = doctor(&cfg, "fakefolder", &opts).await;
    let s = step(&report, "profile");
    assert_eq!(s.status, StepStatus::Fail, "{}", report.text());
    let enable = format!("cmux harness enable fakefolder --folder {}", folder.display());
    assert_eq!(s.fix.as_deref(), Some(enable.as_str()), "{}", report.text());
    assert_eq!(s.fix, next());

    // Enabled: doctored like any profile, started inside its folder.
    let sha = folder_profiles::load_one(&cfg, &gate, &folder, "fakefolder")
        .and_then(|fp| fp.sha256)
        .unwrap();
    folder_profiles::enable(&cfg, &gate, &folder, "fakefolder", &sha).unwrap();
    let report = doctor(&cfg, "fakefolder", &opts).await;
    assert!(report.ok, "{}", report.text());
    for name in ["profile", "command", "env", "launch", "initialize", "session", "prompt"] {
        assert_eq!(step(&report, name).status, StepStatus::Pass, "{}", report.text());
    }
    let launch = &step(&report, "launch").detail;
    assert!(launch.ends_with(&format!(" in {}", folder.display())), "{launch}");

    // Without a folder to look in, the id is unknown.
    opts.folder = None;
    let report = doctor(&cfg, "fakefolder", &opts).await;
    assert_eq!(step(&report, "profile").status, StepStatus::Fail);
    assert!(step(&report, "profile").detail.contains("no harness"), "{}", report.text());
}

/// A managed Codex install reports whether it told a running daemon to read its profiles again,
/// so a daemon that was running does not keep offering the catalog it had before the install.
#[test]
fn a_codex_runtime_install_reports_the_daemon_reload() {
    let installed = json!({"version": "0.156.1", "ready": true});
    let reloaded = with_daemon_reloaded(installed.clone(), true);
    assert_eq!(reloaded["daemonReloaded"], true);
    assert_eq!(reloaded["version"], "0.156.1");
    assert_eq!(with_daemon_reloaded(installed, false)["daemonReloaded"], false);
}

/// `cmux harness add --example hermes` (or `hermes-agent`) writes a profile
/// that loads as an ACP harness running `hermes acp`.
#[test]
fn hermes_example_profile_loads_as_an_acp_harness() {
    let text = example("hermes").expect("a hermes example");
    assert_eq!(example("hermes-agent"), Some(text));
    let path = std::path::Path::new("/tmp/hermes.toml");
    let (id, profile, meta, warnings) = crate::config::profiles::parse_profile_toml(
        text,
        path,
        Some("hermes"),
        crate::config::ProfileSource::UserFile,
    )
    .unwrap();
    assert!(warnings.is_empty(), "{warnings:?}");
    assert_eq!(id, "hermes");
    assert_eq!(profile.kind, crate::config::HarnessKind::Acp);
    assert_eq!(profile.argv.last().map(String::as_str), Some("acp"));
    assert_eq!(meta.display_name.as_deref(), Some("Hermes Agent"));
}

fn add_into(dir: &Path, req: AddRequest) -> (Added, HarnessProfile) {
    let sources = ProfileSources { user_dir: Some(dir.to_owned()), ..ProfileSources::none() };
    let added = add(&req, &sources).unwrap();
    let text = std::fs::read_to_string(&added.path).unwrap();
    let (_, profile, _, _) =
        profiles::parse_profile_toml(&text, &added.path, Some(&added.id), ProfileSource::UserFile)
            .unwrap();
    (added, profile)
}

#[test]
fn add_writes_args_env_and_claude_home_into_the_example() {
    let dir = temp("add-launch-claude");
    let launch = LaunchEdits {
        args: vec!["--verbose".into()],
        env: parse_env_args(&["DISABLE_TELEMETRY=1".into()]).unwrap(),
        home: Some("~/.claude-work".into()),
    };
    let req = AddRequest {
        id: None,
        command: Some("/opt/claude-beta/claude".into()),
        protocol: "acp".into(),
        example: Some("claude".into()),
        force: false,
        launch,
    };
    let (added, profile) = add_into(&dir, req);
    assert_eq!(added.id, "claude", "the example's id: it replaces the built-in claude");
    assert_eq!(profile.kind, HarnessKind::ClaudeStdio);
    assert_eq!(profile.argv, ["/opt/claude-beta/claude", "--verbose"]);
    assert_eq!(profile.env.get("CLAUDE_CONFIG_DIR").map(String::as_str), Some("~/.claude-work"));
    assert_eq!(profile.env.get("DISABLE_TELEMETRY").map(String::as_str), Some("1"));
    let text = std::fs::read_to_string(&added.path).unwrap();
    assert!(text.contains("[sessions]"), "the example's other tables stay");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn add_writes_launch_into_a_scaffold_and_codex_home() {
    let dir = temp("add-launch-codex");
    let req = AddRequest {
        id: Some("codex-work".into()),
        command: Some("codex-acp".into()),
        protocol: "acp".into(),
        example: None,
        force: false,
        launch: LaunchEdits {
            args: vec!["-c".into(), "x=1".into()],
            env: vec![],
            home: Some("/w/.codex".into()),
        },
    };
    let (_, profile) = add_into(&dir, req);
    assert_eq!(profile.argv, ["codex-acp", "-c", "x=1"]);
    assert_eq!(profile.env.get("CODEX_HOME").map(String::as_str), Some("/w/.codex"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn add_without_launch_flags_writes_the_example_unchanged() {
    let dir = temp("add-launch-none");
    let req = AddRequest {
        id: None,
        command: None,
        protocol: "acp".into(),
        example: Some("codex".into()),
        force: false,
        launch: LaunchEdits::default(),
    };
    let (added, _) = add_into(&dir, req);
    let text = std::fs::read_to_string(&added.path).unwrap();
    assert_eq!(text, with_id(example("codex").unwrap(), "codex"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn env_flags_refuse_secrets_and_bad_names_and_home_needs_a_known_agent() {
    assert!(parse_env_args(&["ANTHROPIC_API_KEY=sk-1".into()]).is_err());
    assert!(parse_env_args(&["bad name=1".into()]).is_err());
    assert!(parse_env_args(&["NOEQUALS".into()]).is_err());
    assert_eq!(parse_env_args(&["A=b=c".into()]).unwrap(), [("A".to_owned(), "b=c".to_owned())]);
    let launch = LaunchEdits { home: Some("/h".into()), ..Default::default() };
    let err = with_launch(&scaffold("goose", "goose", "acp"), None, &launch).unwrap_err();
    assert!(err.to_string().contains("--env ITS_HOME_VAR"), "{err}");
}
