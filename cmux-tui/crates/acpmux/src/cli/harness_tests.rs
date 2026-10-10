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
