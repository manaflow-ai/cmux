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

fn sources(dir: &Path) -> ProfileSources {
    ProfileSources { managed: vec![], user_dir: Some(dir.join("harnesses")), cmux_json: None }
}

/// A config with one profile file `<id>.toml` holding `text`.
fn config_with(name: &str, id: &str, text: &str) -> Config {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp(name);
    let user = dir.join("harnesses");
    std::fs::create_dir_all(&user).unwrap();
    let path = user.join(format!("{id}.toml"));
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    Config::load_from_with(&dir.join("config.json"), &sources(&dir)).unwrap()
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
    }
}

fn step<'a>(report: &'a DoctorReport, name: &str) -> &'a Step {
    report
        .steps
        .iter()
        .find(|s| s.step == name)
        .unwrap_or_else(|| panic!("no step {name}: {report:?}"))
}

#[test]
fn the_scaffold_is_a_valid_profile_for_both_protocols() {
    for protocol in ["acp", "terminal"] {
        let text = scaffold("acme-agent", "/opt/acme/bin/acme", protocol);
        let parsed = profiles::parse_profile_toml(
            &text,
            Path::new("/x/acme-agent.toml"),
            Some("acme-agent"),
            ProfileSource::UserFile,
        );
        let (id, profile, meta, warnings) = parsed.unwrap();
        assert_eq!(id, "acme-agent");
        assert_eq!(profile.argv, ["/opt/acme/bin/acme"]);
        assert_eq!(meta.display_name.as_deref(), Some("Acme agent"));
        assert!(warnings.is_empty(), "{warnings:?}");
    }
}

#[test]
fn every_shipped_example_loads_without_errors() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp("examples");
    let user = dir.join("harnesses");
    std::fs::create_dir_all(&user).unwrap();
    for (id, text) in EXAMPLES {
        let path = user.join(format!("{id}.toml"));
        std::fs::write(&path, text).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let loaded = profiles::load(&sources(&dir));
    assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
    assert_eq!(loaded.profiles.len(), EXAMPLES.len());
    assert_eq!(loaded.profiles["aider"].0.kind, HarnessKind::Terminal);
    assert_eq!(loaded.profiles["claude"].0.kind, HarnessKind::ClaudeStdio);
    assert!(loaded.profiles.values().all(|(_, m)| m.sessions.is_some()));
    assert_eq!(example("claude-code"), example("claude"));
}

#[test]
fn add_writes_a_private_file_and_never_overwrites_unasked() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp("add");
    let src = sources(&dir);
    let req = |id: Option<&str>, example: Option<&str>, force: bool| AddRequest {
        id: id.map(str::to_owned),
        command: Some("/usr/local/bin/acme-agent".into()),
        protocol: "acp".into(),
        example: example.map(str::to_owned),
        force,
    };
    let added = add(&req(None, None, false), &src).unwrap();
    assert_eq!(added.id, "acme-agent");
    assert!(added.diagnostics.is_empty(), "{:?}", added.diagnostics);
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&added.path), 0o600);
    assert_eq!(mode(added.path.parent().unwrap()), 0o700);
    let again = add(&req(None, None, false), &src).err().unwrap().to_string();
    assert!(again.contains("--force") && again.contains("doctor"), "{again}");
    assert!(add(&req(None, None, true), &src).is_ok());
    // An example under another id gets that id.
    let work = add(&req(Some("work-codex"), Some("codex"), false), &src).unwrap();
    let text = std::fs::read_to_string(&work.path).unwrap();
    assert!(text.contains("id = \"work-codex\"") && text.contains("codex-acp"), "{text}");
    assert!(work.diagnostics.is_empty(), "{:?}", work.diagnostics);
    assert!(add(&req(None, Some("nope"), false), &src).is_err());
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_passes_a_working_acp_harness_end_to_end() {
    let cfg = config_with(
        "doctor-ok",
        "fake",
        &format!("id = \"fake\"\nname = \"Fake\"\ncommand = \"python3\"\nargs = [{FAKE:?}]\n"),
    );
    let report = doctor(&cfg, "fake", &options(&[])).await;
    assert!(report.ok, "{}", report.text());
    for name in ["profile", "command", "env", "launch", "initialize", "session", "prompt"] {
        assert_eq!(step(&report, name).status, StepStatus::Pass, "{}", report.text());
    }
    assert!(report.reply.as_deref().unwrap().contains(DOCTOR_PROMPT), "{}", report.text());
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_names_a_missing_program_and_the_fix() {
    let cfg = config_with(
        "doctor-missing",
        "gone",
        "id = \"gone\"\ncommand = \"cmux-no-such-harness-binary\"\n[auth]\ndocs = \"https://example.com/install\"\n",
    );
    let report = doctor(&cfg, "gone", &options(&[])).await;
    assert!(!report.ok);
    let s = step(&report, "command");
    assert_eq!(s.status, StepStatus::Fail);
    let fix = s.fix.as_deref().unwrap();
    assert!(fix.contains("install `cmux-no-such-harness-binary`"), "{fix}");
    assert!(fix.contains("https://example.com/install") && fix.contains("gone.toml"), "{fix}");
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_names_a_missing_keychain_item_and_the_fix() {
    let cfg = config_with(
        "doctor-keychain",
        "kc",
        "id = \"kc\"\ncommand = \"python3\"\n[env]\nKC_API_KEY = { keychain = \"cmux-harness/kc/KC_API_KEY\" }\n",
    );
    let report = doctor(&cfg, "kc", &options(&[])).await;
    let s = step(&report, "env");
    assert_eq!(s.status, StepStatus::Fail, "{}", report.text());
    assert!(s.fix.as_deref().unwrap().contains("cmux harness secret set kc KC_API_KEY"), "{s:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_never_prints_an_env_value_even_when_the_harness_does() {
    let cfg = config_with(
        "doctor-mask",
        "leaky",
        "id = \"leaky\"\ncommand = \"sh\"\nargs = [\"-c\", \"echo token=$LEAKY_TOKEN >&2; echo not-json $LEAKY_TOKEN; exit 3\"]\n[env]\nLEAKY_TOKEN = { env = \"DOC_SECRET\" }\n",
    );
    let report = doctor(&cfg, "leaky", &options(&[("DOC_SECRET", "s3cret-value-123")])).await;
    assert!(!report.ok);
    assert_eq!(step(&report, "initialize").status, StepStatus::Fail);
    let all = format!("{}\n{}", report.text(), serde_json::to_string(&report).unwrap());
    assert!(!all.contains("s3cret-value-123"), "{all}");
    assert!(step(&report, "stderr").detail.contains("token=***"), "{all}");
    assert!(step(&report, "env").detail.contains("LEAKY_TOKEN (login env)"), "{all}");
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_skips_acp_for_a_terminal_harness() {
    let cfg = config_with(
        "doctor-terminal",
        "tui",
        "id = \"tui\"\nprotocol = \"terminal\"\ncommand = \"sh\"\n",
    );
    let report = doctor(&cfg, "tui", &options(&[])).await;
    assert!(report.ok, "{}", report.text());
    let acp = step(&report, "acp");
    assert_eq!(acp.status, StepStatus::Skip);
    assert!(acp.detail.contains("cmux harness run tui"));
}

#[test]
fn list_rows_name_the_source_of_each_profile() {
    let cfg = config_with("list", "acme", "id = \"acme\"\nname = \"Acme\"\ncommand = \"acme\"\n");
    let rows = list_rows(&cfg);
    let acme = rows.iter().find(|r| r.id == "acme").unwrap();
    assert_eq!(
        (acme.source.as_str(), acme.name.as_str(), acme.kind.as_str()),
        ("user-file", "Acme", "acp")
    );
    assert!(acme.path.as_deref().unwrap().ends_with("acme.toml"));
}

#[test]
fn the_guide_schema_example_is_a_valid_profile() {
    use std::os::unix::fs::PermissionsExt;
    let start = GUIDE.find("```toml\nschema = 1").unwrap() + "```toml\n".len();
    let end = start + GUIDE[start..].find("```").unwrap();
    let dir = temp("guide");
    let path = dir.join("acme.toml");
    std::fs::write(&path, &GUIDE[start..end]).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(dir.join("acme.svg"), "<svg/>").unwrap();
    let parsed = profiles::parse_profile_toml(
        &GUIDE[start..end],
        &path,
        Some("acme"),
        ProfileSource::UserFile,
    );
    let (_, profile, meta, warnings) = parsed.unwrap();
    assert!(warnings.is_empty(), "{warnings:?}");
    assert_eq!(profile.env["ACME_API_KEY"], "${keychain:cmux-harness/acme/ACME_API_KEY}");
    assert!(meta.sessions.is_some() && meta.auth.is_some());
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
