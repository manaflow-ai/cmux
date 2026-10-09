use super::*;

/// A private scratch root with `repo/.cmux/harnesses`, and a config whose
/// trust and enable records live in the scratch root.
struct Fx {
    root: PathBuf,
    folder: PathBuf,
    gate: FolderGate,
    cfg: Config,
}

fn fx(name: &str) -> Fx {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-folder-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(profile_dir(&root.join("repo"))).unwrap();
    std::fs::create_dir_all(root.join("repo").join("sub")).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let gate = FolderGate {
        enable_record: root.join("acpmux").join(ENABLE_RECORD),
        trust: trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
        },
    };
    let mut cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    cfg.harnesses.insert(
        "claude".into(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["claude".into()],
            env: Default::default(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    Fx { folder: root.join("repo"), root, gate, cfg }
}

fn write(path: &Path, text: &str, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

impl Fx {
    fn profile(&self, id: &str, text: &str) -> PathBuf {
        let path = profile_dir(&self.folder).join(format!("{id}.toml"));
        write(&path, text, 0o600);
        path
    }
    fn trust(&self, level: &str) {
        trust::set(&self.gate.trust, &self.folder.to_string_lossy(), level).unwrap();
    }
    fn state(&self, id: &str) -> FolderState {
        load_one(&self.cfg, &self.gate, &self.folder, id).expect("profile file").state
    }
    fn sha(&self, id: &str) -> String {
        load_one(&self.cfg, &self.gate, &self.folder, id).unwrap().sha256.expect("sha256")
    }
    fn enable(&self, id: &str) -> Result<FolderProfile, String> {
        enable(&self.cfg, &self.gate, &self.folder, id, &self.sha(id))
    }
    fn resolve(
        &self,
        id: &str,
        cwd: &Path,
        remote: bool,
    ) -> Option<Result<HarnessProfile, String>> {
        resolve_for_session(&self.cfg, id, cwd, remote)
            .map(|r| r.map(|(p, _)| p).map_err(|e| e.message))
    }
    fn inside(&self) -> PathBuf {
        self.folder.join("sub")
    }
}

const ACME: &str = r#"
schema = 1
id = "acme"
name = "Acme"
command = "/bin/echo"
args = ["acp", "--model", "${model}"]

[env]
ACME_REGION = "us-east-1"
ACME_API_KEY = { keychain = "cmux-harness/acme/ACME_API_KEY" }
ACME_HOME = { env = "ACME_HOME" }
"#;

#[test]
fn a_folder_without_a_trusted_answer_cannot_enable_or_run_its_profile() {
    let f = fx("untrusted");
    f.profile("acme", ACME);
    assert_eq!(f.state("acme"), FolderState::NeedsTrust);
    let refused = f.enable("acme").unwrap_err();
    assert!(refused.contains("not trusted"), "{refused}");
    let run = f.resolve("acme", &f.inside(), false).expect("the file is found").unwrap_err();
    assert!(run.contains("Trust"), "{run}");
    f.trust("untrusted");
    assert_eq!(f.state("acme"), FolderState::NeedsTrust);
    assert!(f.enable("acme").is_err());
}

#[test]
fn a_trusted_folder_profile_runs_only_after_enable_and_only_inside_the_folder() {
    let f = fx("enable");
    f.profile("acme", ACME);
    f.trust("trusted");
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
    let run = f.resolve("acme", &f.inside(), false).unwrap().unwrap_err();
    assert!(run.contains("cmux harness enable acme --folder"), "{run}");
    let enabled = f.enable("acme").unwrap();
    assert_eq!(enabled.state, FolderState::Enabled);
    let profile = f.resolve("acme", &f.inside(), false).unwrap().unwrap();
    assert_eq!(profile.argv, ["/bin/echo", "acp", "--model", "${model}"]);
    assert!(f.resolve("acme", &f.folder, false).unwrap().is_ok());
    // Outside the folder no folder has the file: an unknown harness.
    assert!(f.resolve("acme", &f.root, false).is_none());
    // An in-code config has no folder profiles at all.
    let bare = Config::default();
    assert!(resolve_for_session(&bare, "acme", &f.inside(), false).is_none());
}

#[test]
fn any_byte_change_in_the_file_or_its_icon_needs_a_new_confirmation() {
    let f = fx("bytes");
    let path = f.profile("acme", &format!("icon = \"acme.svg\"\n{ACME}"));
    write(&profile_dir(&f.folder).join("acme.svg"), "<svg/>", 0o600);
    f.trust("trusted");
    f.enable("acme").unwrap();
    assert_eq!(f.state("acme"), FolderState::Enabled);
    write(&path, &format!("icon = \"acme.svg\"\n{ACME}\n# changed\n"), 0o600);
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
    assert!(f.resolve("acme", &f.inside(), false).unwrap().is_err());
    f.enable("acme").unwrap();
    write(&profile_dir(&f.folder).join("acme.svg"), "<svg><path/></svg>", 0o600);
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
}

#[test]
fn enable_records_only_the_bytes_that_were_shown() {
    let f = fx("shown");
    f.profile("acme", ACME);
    f.trust("trusted");
    let stale = f.sha("acme");
    f.profile("acme", &format!("{ACME}\n# edited after the prompt\n"));
    let refused = enable(&f.cfg, &f.gate, &f.folder, "acme", &stale).unwrap_err();
    assert!(refused.contains("changed"), "{refused}");
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
}

#[test]
fn a_withdrawn_trust_answer_stops_an_enabled_profile() {
    let f = fx("revoke");
    f.profile("acme", ACME);
    f.trust("trusted");
    f.enable("acme").unwrap();
    f.trust("untrusted");
    assert_eq!(f.state("acme"), FolderState::NeedsTrust);
    assert!(f.resolve("acme", &f.inside(), false).unwrap().is_err());
}

#[test]
fn damaged_records_fail_closed_and_are_never_overwritten() {
    let f = fx("damaged");
    f.profile("acme", ACME);
    f.trust("trusted");
    f.enable("acme").unwrap();
    write(&f.gate.enable_record, "{not json", 0o600);
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
    assert!(f.enable("acme").unwrap_err().contains("damaged"));
    assert!(disable(&f.gate, &f.folder, "acme").is_err());
    assert_eq!(std::fs::read_to_string(&f.gate.enable_record).unwrap(), "{not json");
    write(&f.gate.trust.record, "{not json", 0o600);
    assert_eq!(f.state("acme"), FolderState::NeedsTrust);
}

#[test]
fn a_folder_profile_cannot_replace_a_catalog_harness_or_family() {
    let f = fx("shadow");
    f.profile("claude", &ACME.replace("\"acme\"", "\"claude\""));
    f.trust("trusted");
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "claude").unwrap();
    assert_eq!(fp.state, FolderState::Error);
    assert!(fp.diagnostics.iter().any(|d| d.message.contains("cannot replace")), "{fp:?}");
    assert!(refusal(&fp).is_some());
    // The catalog answers its own names; the folder file is never consulted.
    assert!(f.resolve("claude", &f.inside(), false).is_none());
}

#[test]
fn web_and_peer_sessions_cannot_start_a_folder_profile() {
    let f = fx("remote");
    f.profile("acme", ACME);
    f.trust("trusted");
    f.enable("acme").unwrap();
    let refused = f.resolve("acme", &f.inside(), true).unwrap().unwrap_err();
    assert!(refused.contains("Web or peer"), "{refused}");
}

#[test]
fn folder_files_follow_the_managed_rules() {
    let f = fx("rules");
    f.trust("trusted");
    let error = |id: &str, text: &str| {
        f.profile(id, text);
        let fp = load_one(&f.cfg, &f.gate, &f.folder, id).unwrap();
        assert_eq!(fp.state, FolderState::Error, "{id}: {fp:?}");
        fp
    };
    let secret = ACME.replace("acme", "lit").replace(
        "ACME_REGION = \"us-east-1\"",
        "ACME_REGION = \"us-east-1\"\nACME_TOKEN = \"abc123\"",
    );
    let fp = error("lit", &secret);
    assert!(fp.diagnostics.iter().all(|d| !d.message.contains("abc123")), "{fp:?}");
    error("rel", &ACME.replace("acme", "rel").replace("/bin/echo", "./bin/agent"));
    // The icon exists, but outside the profile folder.
    write(&f.folder.join(".cmux").join("icon.svg"), "<svg/>", 0o600);
    error("icon", &format!("icon = \"../icon.svg\"\n{}", ACME.replace("acme", "icon")));
    let path = f.profile("open", &ACME.replace("acme", "open"));
    write(&path, &ACME.replace("acme", "open"), 0o664);
    assert_eq!(f.state("open"), FolderState::Error);
    let target = f.root.join("elsewhere.toml");
    write(&target, &ACME.replace("acme", "link"), 0o600);
    std::os::unix::fs::symlink(&target, profile_dir(&f.folder).join("link.toml")).unwrap();
    assert_eq!(f.state("link"), FolderState::Error);
}

#[test]
fn the_confirmation_shows_the_command_and_each_env_source() {
    let f = fx("confirm");
    f.profile("acme", &ACME.replace("[env]", "[env]\nNODE_OPTIONS = \"--require ./x.js\""));
    f.trust("trusted");
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "acme").unwrap();
    let text = confirmation_text(&fp, Some(Path::new("/bin/echo")));
    assert!(text.contains("/bin/echo acp --model ${model}"), "{text}");
    assert!(text.contains("ACME_API_KEY = Keychain item \"cmux-harness/acme/ACME_API_KEY\""));
    assert!(text.contains("ACME_HOME = your login variable ACME_HOME"), "{text}");
    assert!(text.contains("us-east-1 (plain)"), "{text}");
    assert!(text.contains("NODE_OPTIONS changes which code"), "{text}");
    assert!(text.contains(fp.sha256.as_deref().unwrap()), "{text}");
    let inside = f.folder.join("bin").join("agent");
    let text = confirmation_text(&fp, Some(&inside));
    assert!(text.contains("inside this folder"), "{text}");
}

#[test]
fn disable_withdraws_the_confirmation() {
    let f = fx("disable");
    f.profile("acme", ACME);
    f.trust("trusted");
    f.enable("acme").unwrap();
    assert!(disable(&f.gate, &f.folder, "acme").unwrap());
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
    assert!(!disable(&f.gate, &f.folder, "acme").unwrap());
}

#[test]
fn scan_lists_every_folder_profile_with_its_state() {
    let f = fx("scan");
    f.profile("acme", ACME);
    f.profile("beta", &ACME.replace("acme", "beta"));
    let rows = scan(&f.cfg, &f.gate, &f.folder).unwrap();
    let states: Vec<(&str, FolderState)> = rows.iter().map(|r| (r.id.as_str(), r.state)).collect();
    assert_eq!(states, [("acme", FolderState::NeedsTrust), ("beta", FolderState::NeedsTrust)]);
    let json = serde_json::to_string(&rows).unwrap();
    assert!(!json.contains("us-east-1"), "{json}");
    assert!(scan(&f.cfg, &f.gate, &f.root).unwrap().is_empty());
}

#[test]
fn the_confirmation_never_prints_raw_control_characters() {
    let f = fx("escapes");
    let hidden = ACME.replace(
        "args = [\"acp\", \"--model\", \"${model}\"]",
        "args = [\"acp\", \"\\u001b[2K\\rsafe\", \"x\\ny\"]",
    );
    f.profile("acme", &hidden.replace("us-east-1", "east\\u001b[8m\\u202egnp"));
    f.trust("trusted");
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "acme").unwrap();
    let text = confirmation_text(&fp, Some(Path::new("/bin/echo")));
    let body: String = text.lines().collect::<Vec<_>>().join("");
    assert!(!body.chars().any(|c| c.is_control() || c == '\u{202e}'), "{text:?}");
    assert!(text.contains("\\u{202e}gnp"), "{text}");
    assert!(text.contains("\\x1b[2K\\rsafe"), "{text}");
}

/// A profile that runs `command` with `args` (TOML array text) and `env`.
fn runner(command: &str, args: &str, env: &str) -> String {
    format!("schema = 1\nid = \"acme\"\ncommand = {command:?}\nargs = {args}\n\n[env]\n{env}\n")
}

#[test]
fn a_change_to_a_program_or_argument_file_inside_the_folder_needs_a_new_confirmation() {
    let f = fx("files");
    for dir in ["bin", "scripts", "conf"] {
        std::fs::create_dir_all(f.folder.join(dir)).unwrap();
    }
    let program = f.folder.join("bin").join("agent");
    write(&program, "#!/bin/sh\necho one\n", 0o700);
    write(&f.folder.join("scripts").join("run.js"), "console.log(1)\n", 0o600);
    write(&f.folder.join("conf").join("x.json"), "{}\n", 0o600);
    let args = r#"["scripts/run.js", "--config=conf/x.json", "--model", "${model}"]"#;
    f.profile("acme", &runner(&program.to_string_lossy(), args, ""));
    f.trust("trusted");
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "acme").unwrap();
    let checked: Vec<&str> = fp.checked_files.iter().map(String::as_str).collect();
    assert_eq!(checked.len(), 3, "{checked:?}");
    for (file, text) in [
        (program.clone(), "#!/bin/sh\necho two\n"),
        (f.folder.join("scripts").join("run.js"), "console.log(2)\n"),
        (f.folder.join("conf").join("x.json"), "{\"x\":1}\n"),
    ] {
        f.enable("acme").unwrap();
        assert_eq!(f.state("acme"), FolderState::Enabled);
        write(&file, text, 0o600);
        assert_eq!(f.state("acme"), FolderState::NeedsEnable, "{}", file.display());
        assert!(f.resolve("acme", &f.inside(), false).unwrap().is_err());
    }
}

#[test]
fn a_program_found_on_the_profile_path_inside_the_folder_is_checked() {
    let f = fx("pathfile");
    std::fs::create_dir_all(f.folder.join("tools")).unwrap();
    let program = f.folder.join("tools").join("acme-agent");
    write(&program, "#!/bin/sh\necho one\n", 0o700);
    let env = format!("PATH = \"{}:/usr/bin:/bin\"", f.folder.join("tools").display());
    f.profile("acme", &runner("acme-agent", "[]", &env));
    f.trust("trusted");
    f.enable("acme").unwrap();
    write(&program, "#!/bin/sh\necho two\n", 0o700);
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
    // Retargeting a link inside the folder also asks again.
    let link_target = f.root.join("outside-agent");
    write(&link_target, "#!/bin/sh\n", 0o700);
    std::fs::remove_file(&program).unwrap();
    std::os::unix::fs::symlink(&link_target, &program).unwrap();
    assert_eq!(f.state("acme"), FolderState::NeedsEnable);
}

#[test]
fn the_confirmation_names_checked_files_and_warns_about_download_launchers() {
    let f = fx("launcher");
    std::fs::create_dir_all(f.folder.join("bin")).unwrap();
    let program = f.folder.join("bin").join("agent");
    write(&program, "#!/bin/sh\n", 0o700);
    f.profile("acme", &runner(&program.to_string_lossy(), "[]", ""));
    f.trust("trusted");
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "acme").unwrap();
    let text = confirmation_text(&fp, Some(&program));
    assert!(text.contains(&format!("checked: {}", program.display())), "{text}");
    assert!(!text.contains("is not checked again"), "{text}");
    f.profile("acme", &runner("npx", r#"["-y", "acme-agent@latest", "acp"]"#, ""));
    let fp = load_one(&f.cfg, &f.gate, &f.folder, "acme").unwrap();
    let text = confirmation_text(&fp, Some(Path::new("/usr/local/bin/npx")));
    assert!(text.contains("downloads"), "{text}");
}
