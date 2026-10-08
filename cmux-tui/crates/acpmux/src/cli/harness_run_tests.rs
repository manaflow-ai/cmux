use super::*;
use crate::config::ProfileSources;
use crate::config::folder_profiles::FolderGate;

fn temp(name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-run-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("harnesses")).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::canonicalize(&dir).unwrap()
}

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// A config with user profile files `files` (id, text).
fn config_with(dir: &Path, files: &[(&str, &str)]) -> Config {
    for (id, text) in files {
        write(&dir.join("harnesses").join(format!("{id}.toml")), text);
    }
    let sources =
        ProfileSources { managed: vec![], user_dir: Some(dir.join("harnesses")), cmux_json: None };
    Config::load_from_with(&dir.join("config.json"), &sources).unwrap()
}

const AIDER: &str = r#"
schema = 1
id = "aider-t"
protocol = "terminal"
command = "/usr/bin/aider"
args = ["--model", "${model}", "--root", "${cwd}"]

[env]
AIDER_REGION = "eu"
AIDER_API_KEY = { keychain = "cmux-harness/aider-t/AIDER_API_KEY" }
AIDER_HOME = { env = "AIDER_HOME" }

[defaults]
model = "sonnet"
"#;

const ACP: &str = "schema = 1\nid = \"acme\"\ncommand = \"/usr/bin/acme\"\n";

fn env_lookup(var: &str) -> Option<String> {
    (var == "AIDER_HOME").then(|| "/home/x/.aider".to_owned())
}

fn keychain_ok(service: &str, account: Option<&str>) -> Result<String, String> {
    if service == "cmux-harness" && account == Some("aider-t/AIDER_API_KEY") {
        Ok("sk-value".into())
    } else {
        Err("not found".into())
    }
}

fn keychain_none(_: &str, _: Option<&str>) -> Result<String, String> {
    Err("not found".into())
}

fn lookups() -> Lookups<'static> {
    Lookups { env: &env_lookup, keychain: &keychain_ok }
}

#[test]
fn a_terminal_harness_runs_with_its_resolved_env_in_the_folder() {
    let dir = temp("terminal");
    let cfg = config_with(&dir, &[("aider-t", AIDER)]);
    let plan = run_plan(&cfg, "aider-t", &dir, None, &lookups()).unwrap();
    let root = dir.to_string_lossy().into_owned();
    assert_eq!(plan.argv, ["/usr/bin/aider", "--model", "sonnet", "--root", root.as_str()]);
    assert_eq!(plan.cwd, dir);
    assert_eq!(plan.env["AIDER_REGION"], "eu");
    assert_eq!(plan.env["AIDER_API_KEY"], "sk-value");
    assert_eq!(plan.env["AIDER_HOME"], "/home/x/.aider");
    let plan = run_plan(&cfg, "aider-t", &dir, Some("opus"), &lookups()).unwrap();
    assert_eq!(plan.argv[2], "opus");
}

#[test]
fn acp_and_unknown_harnesses_are_refused() {
    let dir = temp("refused");
    let cfg = config_with(&dir, &[("acme", ACP)]);
    let e = run_plan(&cfg, "acme", &dir, None, &lookups()).unwrap_err().to_string();
    assert!(e.contains("agent chat"), "{e}");
    let e = run_plan(&cfg, "nope", &dir, None, &lookups()).unwrap_err().to_string();
    assert!(e.contains("unknown harness"), "{e}");
}

#[test]
fn a_missing_secret_or_model_names_what_is_missing_never_a_value() {
    let dir = temp("missing");
    let cfg = config_with(&dir, &[("aider-t", AIDER)]);
    let none = Lookups { env: &env_lookup, keychain: &keychain_none };
    let e = run_plan(&cfg, "aider-t", &dir, None, &none).unwrap_err().to_string();
    assert!(e.contains("AIDER_API_KEY"), "{e}");
    let no_model = AIDER.replace("[defaults]\nmodel = \"sonnet\"\n", "");
    let cfg = config_with(&dir, &[("aider-t", &no_model)]);
    let e = run_plan(&cfg, "aider-t", &dir, None, &lookups()).unwrap_err().to_string();
    assert!(e.contains("--model"), "{e}");
}

#[test]
fn a_folder_terminal_harness_runs_only_when_enabled() {
    let dir = temp("folder");
    let folder = dir.join("repo");
    std::fs::create_dir_all(folder_profiles::profile_dir(&folder)).unwrap();
    let text = AIDER.replace("aider-t", "repo-tool");
    write(&folder_profiles::profile_dir(&folder).join("repo-tool.toml"), &text);
    let gate = FolderGate {
        enable_record: dir.join("enable.json"),
        trust: crate::trust::Paths {
            claude_json: dir.join("claude.json"),
            codex_config: dir.join("config.toml"),
            record: dir.join("trust.json"),
            agent_home: None,
        },
    };
    let mut cfg = config_with(&dir, &[]);
    cfg.folder_gate = Some(gate.clone());
    let keychain = |s: &str, a: Option<&str>| {
        (s == "cmux-harness" && a == Some("repo-tool/AIDER_API_KEY"))
            .then(|| "sk".to_owned())
            .ok_or_else(|| "not found".to_owned())
    };
    let lookups = Lookups { env: &env_lookup, keychain: &keychain };
    crate::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let e = run_plan(&cfg, "repo-tool", &folder, None, &lookups).unwrap_err().to_string();
    assert!(e.contains("cmux harness enable repo-tool"), "{e}");
    let sha = folder_profiles::load_one(&cfg, &gate, &folder, "repo-tool")
        .and_then(|fp| fp.sha256)
        .unwrap();
    folder_profiles::enable(&cfg, &gate, &folder, "repo-tool", &sha).unwrap();
    let plan = run_plan(&cfg, "repo-tool", &folder, None, &lookups).unwrap();
    assert_eq!(plan.argv[0], "/usr/bin/aider");
    assert!(run_plan(&cfg, "repo-tool", &dir, None, &lookups).is_err());
}
