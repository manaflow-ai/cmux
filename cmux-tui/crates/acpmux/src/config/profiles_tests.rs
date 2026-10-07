use super::*;
use crate::config::{Config, HarnessKind};

/// A fresh private folder for one test.
fn temp(name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-profiles-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    path
}

const ACME: &str = r#"
schema = 1
id = "acme"
name = "Acme Agent"
icon = "terminal"
description = "Acme's agent"
command = "acme-agent"
args = ["acp", "--model", "${model}"]

[env]
ACME_REGION = "us-east-1"
ACME_API_KEY = { keychain = "cmux-harness/acme" }
ACME_HOME = { env = "ACME_HOME" }

[defaults]
model = "acme-large"
effort = "medium"
policy = "approve-edits"

[capabilities]
effort = ["low", "medium", "high"]
fast = false
permission_modes = true
resume = true

[models]
list = [
  { id = "acme-large", name = "Acme Large", short_name = "Large", family = "Acme", efforts = ["low", "high"], default_effort = "high", fast = true, context_window = 200000 },
  "acme-small",
]

[auth]
login = "acme-agent login"
docs = "https://acme.example/setup"

[sessions]
adapter = "jsonl"
roots = ["${ACME_HOME:-~/.acme}/sessions"]
layouts = ["~/.acme-accounts/*/sessions"]
files = "*/*.jsonl"
exclude = ["**/subagents/**"]
[sessions.fields]
id = "file.stem"
title = ["last:/customTitle", "first:/message/content"]
cwd = "first:/cwd"
updated = "file.mtime"
count = "count:/type=user"
[sessions.resume]
argv = ["acme-agent", "--resume", "{id}"]
cwd = "{cwd}"
"#;

fn user_only(dir: &Path) -> ProfileSources {
    ProfileSources { managed: vec![], user_dir: Some(dir.to_owned()), cmux_json: None }
}

#[test]
fn a_profile_file_maps_onto_a_harness_profile() {
    let dir = temp("map");
    write(&dir, "acme.toml", ACME);
    let loaded = load(&user_only(&dir));
    assert!(
        loaded.diagnostics.iter().all(|d| d.severity == Severity::Warning),
        "{:?}",
        loaded.diagnostics
    );
    let (p, meta) = &loaded.profiles["acme"];
    assert_eq!(p.kind, HarnessKind::Acp);
    assert_eq!(p.argv, ["acme-agent", "acp", "--model", "${model}"]);
    assert_eq!(p.env["ACME_REGION"], "us-east-1");
    assert_eq!(p.env["ACME_API_KEY"], "${keychain:cmux-harness/acme}");
    assert_eq!(p.env["ACME_HOME"], "${env:ACME_HOME}");
    assert_eq!(p.model.as_deref(), Some("acme-large"));
    assert_eq!(p.effort.as_deref(), Some("medium"));
    assert_eq!(p.policy, Some(PermissionPolicy::ApproveEdits));
    assert_eq!(p.models.iter().map(|m| m.id()).collect::<Vec<_>>(), ["acme-large", "acme-small"]);
    assert_eq!(p.models[0].name(), "Acme Large");
    assert_eq!(meta.source, ProfileSource::UserFile);
    assert_eq!(meta.display_name.as_deref(), Some("Acme Agent"));
    assert_eq!(meta.icon.as_deref(), Some("terminal"));
    let caps = meta.capabilities.as_ref().unwrap();
    assert_eq!(caps.effort, ["low", "medium", "high"]);
    assert_eq!(caps.permission_modes, Some(true));
    let detail = &meta.model_details[0];
    assert_eq!(detail.short_name.as_deref(), Some("Large"));
    assert_eq!(detail.context_window, Some(200_000));
    // The ALL-CHATS-ON-DEVICE sessions block (nx-all-chats DESIGN.md section 5).
    let sessions = serde_json::to_value(meta.sessions.as_ref().unwrap()).unwrap();
    assert_eq!(sessions["adapter"], "jsonl");
    assert_eq!(sessions["layouts"][0], "~/.acme-accounts/*/sessions");
    assert_eq!(sessions["files"], "*/*.jsonl");
    assert_eq!(sessions["fields"]["title"][1], "first:/message/content");
    assert_eq!(sessions["fields"]["id"], "file.stem");
    assert_eq!(sessions["resume"]["argv"][2], "{id}");
    assert_eq!(meta.auth.as_ref().unwrap().login.as_deref(), Some("acme-agent login"));
}

#[test]
fn bad_files_get_diagnostics_and_never_stop_the_others() {
    let dir = temp("bad");
    write(&dir, "acme.toml", ACME);
    write(&dir, "typo.toml", "id = \"typo\"\ncommand = \"x\"\ncomand = \"y\"\n");
    write(&dir, "wrong-name.toml", "id = \"other\"\ncommand = \"x\"\n");
    write(&dir, "spaces.toml", "id = \"spaces\"\ncommand = \"npx acme\"\n");
    write(
        &dir,
        "effort.toml",
        "id = \"effort\"\ncommand = \"x\"\n[capabilities]\neffort = [\"turbo\"]\n",
    );
    write(&dir, "Upper.toml", "id = \"Upper\"\ncommand = \"x\"\n");
    write(&dir, "notes.txt", "not a profile");
    let loaded = load(&user_only(&dir));
    assert_eq!(loaded.profiles.keys().collect::<Vec<_>>(), ["acme"]);
    let errors: Vec<&Diagnostic> =
        loaded.diagnostics.iter().filter(|d| d.severity == Severity::Error).collect();
    let has = |file: &str, text: &str| {
        errors.iter().any(|d| d.path.ends_with(file) && d.message.contains(text))
    };
    assert!(has("typo.toml", "comand"), "{errors:?}");
    assert!(has("wrong-name.toml", "file name must be the id"), "{errors:?}");
    assert!(has("spaces.toml", "has spaces"), "{errors:?}");
    assert!(has("effort.toml", "turbo"), "{errors:?}");
    assert!(has("Upper.toml", "lowercase"), "{errors:?}");
    // Every error says where; fixes are concrete.
    let spaces = errors.iter().find(|d| d.path.ends_with("spaces.toml")).unwrap();
    assert!(spaces.fix.as_deref().unwrap().contains("args"));
}

#[test]
fn a_literal_secret_is_an_error_in_managed_files_and_a_warning_in_user_files() {
    let managed = temp("secret-managed");
    let user = temp("secret-user");
    let text = "id = \"leak\"\ncommand = \"x\"\n[env]\nLEAK_API_KEY = \"sk-live-123456\"\n";
    write(&managed, "leak.toml", text);
    write(&user, "leak2.toml", &text.replace("\"leak\"", "\"leak2\""));
    let loaded =
        load(&ProfileSources { managed: vec![managed], user_dir: Some(user), cmux_json: None });
    assert!(!loaded.profiles.contains_key("leak"));
    assert!(loaded.profiles.contains_key("leak2"));
    let d = |id: &str| loaded.diagnostics.iter().find(|d| d.id.as_deref() == Some(id)).unwrap();
    assert_eq!(d("leak").severity, Severity::Error);
    assert_eq!(d("leak2").severity, Severity::Warning);
    assert!(d("leak").fix.as_deref().unwrap().contains("keychain"));
    // No diagnostic ever carries the value.
    assert!(loaded.diagnostics.iter().all(|d| !format!("{d:?}").contains("sk-live-123456")));
}

#[test]
fn a_file_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp("perm");
    let path = write(&dir, "open.toml", "id = \"open\"\ncommand = \"x\"\n");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
    let loaded = load(&user_only(&dir));
    assert!(loaded.profiles.is_empty());
    let d = &loaded.diagnostics[0];
    assert_eq!(d.severity, Severity::Error);
    assert!(d.fix.as_deref().unwrap().starts_with("chmod go-w"));
}

#[test]
fn managed_wins_over_user_files_and_user_files_over_cmux_json() {
    let managed = temp("prec-managed");
    let user = temp("prec-user");
    write(&managed, "acme.toml", "id = \"acme\"\ncommand = \"/opt/company/acme\"\n");
    write(&user, "acme.toml", "id = \"acme\"\ncommand = \"acme-mine\"\n");
    write(&user, "solo.toml", "id = \"solo\"\ncommand = \"solo-user\"\n");
    let json = write(
        &user,
        "cmux.json",
        r#"{
          // comments are allowed in cmux.json
          "agents": {"harnesses": {
            "solo": {"command": "solo-json"},
            "jsononly": {"command": "j", "args": ["acp"], "name": "From JSON",
                         "models": {"list": [{"id": "m1", "shortName": "M1"}]}}
          }}
        }"#,
    );
    let loaded = load(&ProfileSources {
        managed: vec![managed],
        user_dir: Some(user),
        cmux_json: Some(json),
    });
    assert_eq!(loaded.profiles["acme"].0.argv, ["/opt/company/acme"]);
    assert_eq!(loaded.profiles["acme"].1.source, ProfileSource::Managed);
    assert_eq!(loaded.profiles["solo"].0.argv, ["solo-user"]);
    let (j, jm) = &loaded.profiles["jsononly"];
    assert_eq!(j.argv, ["j", "acp"]);
    assert_eq!(jm.source, ProfileSource::CmuxJson);
    assert_eq!(jm.display_name.as_deref(), Some("From JSON"));
    assert_eq!(jm.model_details[0].short_name.as_deref(), Some("M1"));
    let shadow = loaded
        .diagnostics
        .iter()
        .find(|d| d.id.as_deref() == Some("acme") && d.path.contains("prec-user"))
        .unwrap();
    assert!(shadow.fix.as_deref().unwrap().contains("managed"));
}

#[test]
fn profile_files_join_the_config_and_are_never_saved_to_config_json() {
    let dir = temp("join");
    let user = dir.join("harnesses");
    std::fs::create_dir_all(&user).unwrap();
    write(&user, "acme.toml", ACME);
    write(&user, "mine.toml", "id = \"mine\"\ncommand = \"from-file\"\n");
    let config = write(
        &dir,
        "config.json",
        r#"{"harnesses": {"mine": {"argv": ["from-config-json"]}, "kept": {"argv": ["k"]}}}"#,
    );
    let sources = user_only(&user);
    let cfg = Config::load_from_with(&config, &sources).unwrap();
    assert_eq!(cfg.harnesses["acme"].argv[0], "acme-agent");
    // The profile file wins over config.json.
    assert_eq!(cfg.harnesses["mine"].argv, ["from-file"]);
    assert_eq!(cfg.profile_meta["acme"].display_name.as_deref(), Some("Acme Agent"));
    cfg.save().unwrap();
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
    let saved = saved["harnesses"].as_object().unwrap();
    assert!(!saved.contains_key("acme"), "{saved:?}");
    // config.json keeps its own entry that a file shadowed.
    assert_eq!(saved["mine"]["argv"][0], "from-config-json");
    assert_eq!(saved["kept"]["argv"][0], "k");
}

#[test]
fn a_terminal_profile_never_starts_as_an_acp_child() {
    let dir = temp("terminal");
    write(&dir, "aider.toml", "id = \"aider\"\nprotocol = \"terminal\"\ncommand = \"aider\"\n");
    let loaded = load(&user_only(&dir));
    let (p, _) = &loaded.profiles["aider"];
    assert_eq!(p.kind, HarnessKind::Terminal);
    let err = crate::agent::harness_command("aider", p, &dir, None, None).unwrap_err();
    assert!(err.to_string().contains("cmux harness run aider"), "{err}");
    let refusal = crate::hub::terminal_harness_refusal("aider");
    assert_eq!(refusal.data.as_ref().unwrap()["reason"], "harness.terminal");
}

#[test]
fn env_references_resolve_at_launch_and_errors_name_no_value() {
    let mut env = BTreeMap::from([
        ("PLAIN".to_owned(), "x".to_owned()),
        ("KEY".to_owned(), "${keychain:cmux-harness/acme/KEY}".to_owned()),
        ("HOMEDIR".to_owned(), "${env:ACME_HOME}/data".to_owned()),
        ("CWD".to_owned(), "${cwd}/y".to_owned()),
    ]);
    assert!(has_env_refs(&env));
    resolve_env_refs(
        &mut env,
        &|var| (var == "ACME_HOME").then(|| "/h".to_owned()),
        &|service, account| {
            assert_eq!((service, account), ("cmux-harness", Some("acme/KEY")));
            Ok("s3cret".to_owned())
        },
    )
    .unwrap();
    assert_eq!(env["KEY"], "s3cret");
    assert_eq!(env["HOMEDIR"], "/h/data");
    assert_eq!(env["PLAIN"], "x");
    assert_eq!(env["CWD"], "${cwd}/y");
    let mut missing = BTreeMap::from([("K".to_owned(), "${keychain:svc}".to_owned())]);
    let err =
        resolve_env_refs(&mut missing, &|_| None, &|_, _| Err("not found".into())).unwrap_err();
    assert!(err.contains("K") && err.contains("svc") && err.contains("not found"), "{err}");
}

#[test]
fn declared_models_carry_profile_catalog_fields() {
    let dir = temp("models");
    write(&dir, "acme.toml", ACME);
    let loaded = load(&user_only(&dir));
    let (p, meta) = &loaded.profiles["acme"];
    let v = crate::hub::declared_model_json(&p.models[0], Some(meta));
    assert_eq!(v["id"], "acme-large");
    assert_eq!(v["declared"], true);
    assert_eq!(v["shortName"], "Large");
    assert_eq!(v["efforts"], serde_json::json!(["low", "high"]));
    assert_eq!(v["contextWindow"], 200_000);
    let plain = crate::hub::declared_model_json(&p.models[1], Some(meta));
    assert_eq!(
        plain,
        serde_json::json!({"id": "acme-small", "name": "acme-small", "declared": true})
    );
}

#[test]
fn a_sessions_block_is_validated() {
    let dir = temp("sessions");
    let base = "command = \"x\"\n[sessions]\n";
    let cases = [
        ("unknown-adapter", "adapter = \"zip\"\nroots = [\"/r\"]\n", "adapter"),
        (
            "builtin-fields",
            "adapter = \"codex\"\n[sessions.fields]\nid = \"file.stem\"\n",
            "built-in",
        ),
        (
            "no-files",
            "adapter = \"jsonl\"\nroots = [\"/r\"]\n[sessions.fields]\nid = \"file.stem\"\n",
            "files",
        ),
        (
            "bad-selector",
            "adapter = \"jsonl\"\nroots = [\"/r\"]\nfiles = \"*.jsonl\"\n[sessions.fields]\nid = \"stem\"\n",
            "selector",
        ),
        (
            "sql-write",
            "adapter = \"sqlite\"\nroots = [\"/r\"]\nfiles = \"*.db\"\nquery = \"ATTACH 'x' AS y\"\n",
            "read-only",
        ),
        (
            "resume-both",
            "adapter = \"claude-code\"\n[sessions.resume]\nargv = [\"c\"]\nadopt = true\n",
            "resume",
        ),
    ];
    for (id, body, _) in cases {
        write(&dir, &format!("{id}.toml"), &format!("id = \"{id}\"\n{base}{body}"));
    }
    write(
        &dir,
        "ok-builtin.toml",
        "id = \"ok-builtin\"\ncommand = \"x\"\n[sessions]\nadapter = \"claude-code\"\nlayouts = [\"~/.subrouter/codex/claude/*/projects\"]\n",
    );
    let loaded = load(&user_only(&dir));
    assert_eq!(
        loaded.profiles.keys().collect::<Vec<_>>(),
        ["ok-builtin"],
        "{:?}",
        loaded.diagnostics
    );
    for (id, _, needle) in cases {
        assert!(
            loaded
                .diagnostics
                .iter()
                .any(|d| d.id.as_deref() == Some(id) && d.message.contains(needle)),
            "{id}: {:?}",
            loaded.diagnostics
        );
    }
}
