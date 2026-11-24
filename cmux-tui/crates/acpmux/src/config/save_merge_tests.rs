//! A daemon's save of config.json keeps what another writer changed in the file since the
//! daemon read it: `acpmux config --set`, `machine join`/`leave`, a person's hand edit, and
//! keys a newer build wrote. Before, the save wrote the daemon's whole copy over the file.

use super::*;
use serde_json::{Value, json};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-config-{tag}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn file(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[cfg(unix)]
#[test]
fn a_save_keeps_what_another_writer_changed_since_the_load() {
    let dir = scratch("merge");
    let path = dir.join("config.json");
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({
            "permissionPolicy": "ask",
            "loginEnvAllow": ["NPM_TOKEN"],
            "harnesses": {"mine": {"argv": ["/bin/mine"]}},
        }))
        .unwrap(),
    )
    .unwrap();
    let mut daemon = Config::load_from_with(&path, &ProfileSources::none()).unwrap();

    // Another writer (the CLI, a person, a newer build) changes the file meanwhile.
    let mut outside = file(&path);
    outside["permissionPolicy"] = json!("approve-reads");
    outside["harnesses"]["theirs"] = json!({"argv": ["/bin/theirs"]});
    outside["aKeyOfANewerBuild"] = json!({"kept": true});
    std::fs::write(&path, serde_json::to_vec(&outside).unwrap()).unwrap();

    // The daemon changes something else and saves.
    daemon.login_env_allow.push("PIP_INDEX_URL".into());
    daemon.save().unwrap();

    let saved = file(&path);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(saved["loginEnvAllow"], json!(["NPM_TOKEN", "PIP_INDEX_URL"]), "{saved}");
    assert_eq!(saved["permissionPolicy"], "approve-reads", "the outside edit was lost: {saved}");
    assert_eq!(saved["harnesses"]["theirs"]["argv"], json!(["/bin/theirs"]), "{saved}");
    assert_eq!(saved["harnesses"]["mine"]["argv"], json!(["/bin/mine"]), "{saved}");
    assert_eq!(saved["aKeyOfANewerBuild"], json!({"kept": true}), "{saved}");
}

/// What the daemon itself changed and saved stays its own: a later outside edit of another key
/// is kept, and the daemon's earlier change is not written back over a later outside change of
/// the same key.
#[cfg(unix)]
#[test]
fn a_second_save_keeps_an_outside_change_of_a_key_the_daemon_saved_before() {
    let dir = scratch("merge2");
    let path = dir.join("config.json");
    std::fs::write(&path, br#"{"permissionPolicy": "ask"}"#).unwrap();
    let mut daemon = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    daemon.permission_policy = PermissionPolicy::ApproveReads;
    daemon.save().unwrap();
    assert_eq!(file(&path)["permissionPolicy"], "approve-reads");

    let mut outside = file(&path);
    outside["permissionPolicy"] = json!("deny-all");
    std::fs::write(&path, serde_json::to_vec(&outside).unwrap()).unwrap();
    daemon.login_env_allow.push("NPM_TOKEN".into());
    daemon.save().unwrap();

    let saved = file(&path);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(saved["permissionPolicy"], "deny-all", "{saved}");
    assert_eq!(saved["loginEnvAllow"], json!(["NPM_TOKEN"]), "{saved}");
}
