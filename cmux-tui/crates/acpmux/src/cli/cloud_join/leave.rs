//! `acpmux machine leave` (also `host leave`): the joined machine's own way out, as `tailscale
//! logout` is ("expire the current log in"). It asks the hub to revoke this machine's credential
//! with that credential (`POST /v1/machines/credentials/self/revoke`; the hub drops the machine's
//! mesh address-book rows with it), then removes the join here: the record is marked revoked,
//! `meshRelay` leaves config.json, and the credential file is deleted, with `node.wg.key` only
//! under the WireGuard key lock and never one the cmux link adopted as its own
//! (`key-adopted.json`, or `key-adopted.<install>.json` archived at a sign-out): its paired peers
//! know the link by that key alone (`mesh_node_key::adoption_depends`).
//!
//! A running daemon's relay reads the credential from its file at every hub call
//! (`mesh_http.rs` `token`): with the record revoked and then gone, its next heartbeat or inbox
//! poll is refused and the relay stops for good, with no restart.
//!
//! A hub that cannot revoke a machine from the machine itself (404, or a refusal of the
//! machine's credential on that route) leaves everything here as it was and says to revoke it
//! from the Mac (`cmux machine revoke NAME`); `--local-only` then removes the local state anyway.
use super::*;
use std::path::Path;

/// What the hub said to the revoke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum HubAnswer {
    Revoked,
    /// Already revoked or unknown there: the credential is dead either way.
    AlreadyGone,
    /// This hub has no machine-side revoke: the person revokes it from a signed-in device.
    Unsupported,
    /// No answer, or one that says nothing about the credential (5xx, 429, unreadable).
    Unavailable(String),
    /// Not asked: this home was copied from another box, and the credential is that box's.
    Copy,
}

impl HubAnswer {
    fn label(&self) -> &'static str {
        match self {
            Self::Revoked => "revoked",
            Self::AlreadyGone => "already_revoked",
            Self::Unsupported => "unsupported",
            Self::Unavailable(_) => "unavailable",
            Self::Copy => "not_asked_copy",
        }
    }

    fn revoked(&self) -> bool {
        matches!(self, Self::Revoked | Self::AlreadyGone)
    }
}

/// Reads the hub's refusal of the self-revoke.
pub(super) fn classify(error: &cmux_cloud_client::ApiError) -> HubAnswer {
    match (error.status, error.code.as_deref()) {
        (Some(401), Some("machine.revoked" | "machine.unknown")) => HubAnswer::AlreadyGone,
        // A hub before the self-revoke: no route, or its `{machineId}/revoke` route taking
        // `self` as an id and refusing a machine credential there.
        (Some(401 | 403 | 404 | 405), _) => HubAnswer::Unsupported,
        _ => HubAnswer::Unavailable(error.to_string()),
    }
}

async fn revoke_at_hub(record: &MachineCredential) -> HubAnswer {
    // Always the hub's word: the local revoked bit is set on any 401 from a mesh call, and by
    // a `--local-only` leave cut short, neither of which proves the hub revoked it.
    let Ok(hub) = origin(Some(record.hub_origin.clone())) else {
        return HubAnswer::Unavailable("the stored hub origin is malformed".to_owned());
    };
    let client = match hub_client(&hub, Some(&record.credential)) {
        Ok(client) => client,
        Err(e) => return HubAnswer::Unavailable(format!("{e:#}")),
    };
    match client.machine_redeem_revoke_self().await {
        Ok(_) => HubAnswer::Revoked,
        Err(e) => classify(&cmux_cloud_client::ApiError::from_api(e).await),
    }
}

/// The WireGuard key lock in `home` when the node key there may be deleted: the key is there,
/// no process holds the lock (the cmux link and the WireGuard transport hold it while they use
/// the key), and, checked under it, the link did not adopt the key
/// (`mesh_node_key::lock_to_remove`).
fn node_key_removable(home: &Path) -> Result<Option<cmux_link::key_holder::KeyHolder>> {
    use crate::cli::mesh_node_key::{RemoveLock, lock_to_remove};
    if std::fs::symlink_metadata(cmux_link::key_holder::KeyFile::Node.path_in(home)).is_err() {
        return Ok(None);
    }
    Ok(match lock_to_remove(home)? {
        RemoveLock::Free(holder) => Some(holder),
        RemoveLock::Adopted | RemoveLock::Held => None,
    })
}

/// Removes the join from `home`: the record marked revoked first (so nothing reads it as
/// live if this stops part way), then `meshRelay` (only a joined one), then the credential and
/// the node key, unless the link adopted it or a running process holds it
/// ([`node_key_removable`]). Returns what it removed. The caller holds the join lock.
pub(super) fn remove_local(home: &std::path::Path) -> Result<Vec<&'static str>> {
    let mut removed = Vec::new();
    if let Some(mut record) = load_at(home)?
        && !record.revoked
    {
        record.revoked = true;
        crate::config::private_state_dir(home)?;
        recovery::write_durable(
            &home.join(CREDENTIAL_FILE),
            &serde_json::to_vec_pretty(&record)?,
            true,
        )?;
    }
    let config_path = home.join("config.json");
    if config_path.exists() {
        let mut config = crate::config::Config::load_from(&config_path)?;
        if config
            .mesh_relay
            .as_ref()
            .is_some_and(|relay| relay.credential.as_deref() == Some("join"))
        {
            config.mesh_relay = None;
            config.save_with_writer(|path, bytes| recovery::write_durable(path, bytes, true))?;
            removed.push("meshRelay");
        }
    }
    // Held until the removal is synced.
    let key_lock = node_key_removable(home)?;
    let node_key =
        key_lock.as_ref().map(|_| (cmux_link::key_holder::KeyFile::Node.file_name(), "nodeKey"));
    for (file, label) in [Some((CREDENTIAL_FILE, "credential")), node_key].into_iter().flatten() {
        match std::fs::remove_file(home.join(file)) {
            Ok(()) => removed.push(label),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(anyhow::Error::from(e).context(format!("remove {file}"))),
        }
    }
    recovery::sync_ancestors(home)?;
    drop(key_lock);
    Ok(removed)
}

fn leave_error(code: &str, exit: i32, message: String) -> anyhow::Error {
    crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, code, &message)
        .with_exit(exit)
        .into()
}

pub(super) async fn run(local_only: bool, json_out: bool) -> Result<()> {
    let _lock = join_lock().map_err(|_| store_error())?;
    let home = state_dir();
    let Some(record) = load_at(&home).map_err(|_| store_error())? else {
        // Nothing joined; a stray joined `meshRelay` still goes.
        let removed = remove_local(&home).map_err(|_| store_error())?;
        let out = json!({"left": false, "joined": false, "removed": removed});
        if json_out {
            crate::cli::output::print_json(&out);
        } else {
            println!("not joined; nothing to revoke");
        }
        return Ok(());
    };
    // A copy never revokes the original box's enrollment: it only removes what it holds.
    let copy = copied_here(&home, &record, host_fingerprint::current().as_deref());
    let answer = if copy { HubAnswer::Copy } else { revoke_at_hub(&record).await };
    let mac = format!("cmux machine revoke {}", record.name);
    // Refused unless the hub revoked it or the person asked for a local-only leave.
    let refusal = match &answer {
        _ if local_only => None,
        HubAnswer::Revoked | HubAnswer::AlreadyGone | HubAnswer::Copy => None,
        HubAnswer::Unsupported => Some(leave_error(
            "leave.revoke_from_mac",
            3,
            format!(
                "this hub cannot revoke a machine from the machine itself; revoke it from your Mac (`{mac}`), then run `acpmux machine leave --local-only`. Nothing here changed."
            ),
        )),
        HubAnswer::Unavailable(why) => Some(leave_error(
            "leave.hub_unavailable",
            4,
            format!(
                "the hub did not revoke this machine ({why}); retry, or revoke it from your Mac (`{mac}`) and run `acpmux machine leave --local-only`. Nothing here changed."
            ),
        )),
    };
    if let Some(refusal) = refusal {
        return Err(refusal);
    }
    let removed = remove_local(&home).map_err(|_| store_error())?;
    let daemon = tokio::time::timeout(
        // timeout: a daemon that never answers is reported not running; the leave is done.
        std::time::Duration::from_secs(2),
        crate::client::Client::connect(&crate::config::socket_path()),
    )
    .await;
    let running = matches!(daemon, Ok(Ok(_)));
    let mut out = json!({
        "left": true,
        "machineId": record.machine_id,
        "name": record.name,
        "hubOrigin": record.hub_origin,
        "hub": answer.label(),
        "hubRevoked": answer.revoked(),
        "removed": removed,
        "daemonRunning": running,
    });
    let node_key_kept = !removed.contains(&"nodeKey")
        && std::fs::symlink_metadata(cmux_link::key_holder::KeyFile::Node.path_in(&home)).is_ok();
    if running {
        out["relay"] = json!("stops at its next hub call: its credential is gone");
    }
    if running && !node_key_kept {
        out["nodeKeyNote"] =
            json!("the running daemon makes a new, unjoined node key at its next use");
    }
    if let (true, Some(fields)) = (node_key_kept, out.as_object_mut()) {
        fields.insert(
            "nodeKeyKept".into(),
            json!("the cmux link serves this node key, or a running process holds it"),
        );
    }
    if copy {
        out["hint"] = json!(
            "this home was copied from another machine; that machine keeps its join. Paste a new join line to join this one"
        );
    } else if !answer.revoked() {
        out["hint"] =
            json!(format!("the hub still lists this machine; revoke it from your Mac: {mac}"));
    }
    if json_out {
        crate::cli::output::print_json(&out);
    } else {
        let hub = match &answer {
            HubAnswer::Revoked => "revoked at the hub".to_owned(),
            HubAnswer::AlreadyGone => "already revoked at the hub".to_owned(),
            HubAnswer::Copy => {
                "a copy of another machine's join: the hub was not asked, and that machine keeps its join".to_owned()
            }
            HubAnswer::Unsupported | HubAnswer::Unavailable(_) => {
                format!("NOT revoked at the hub; revoke it from your Mac: {mac}")
            }
        };
        println!("left {} ({}): {hub}", record.name, record.machine_id);
        println!(
            "removed: {}",
            if removed.is_empty() { "nothing".to_owned() } else { removed.join(", ") }
        );
        if running {
            println!("the daemon's mesh relay stops at its next hub call");
        }
        if node_key_kept {
            println!("kept the node key: the cmux link serves it, or a running process holds it");
        }
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use cmux_cloud_client::ApiError;

    #[test]
    fn a_refusal_says_whether_the_credential_is_dead_or_the_mac_must_revoke() {
        let answer =
            |status: u16, body: &str| classify(&ApiError::from_status(status, body.as_bytes()));
        assert_eq!(answer(401, r#"{"code":"machine.revoked"}"#), HubAnswer::AlreadyGone);
        assert_eq!(answer(401, r#"{"code":"machine.unknown"}"#), HubAnswer::AlreadyGone);
        assert_eq!(answer(404, r#"{"code":"machine.not_found"}"#), HubAnswer::Unsupported);
        assert_eq!(answer(404, "<html>no route</html>"), HubAnswer::Unsupported);
        assert_eq!(
            answer(401, r#"{"_tag":"MachineUnauthorized","code":"MachineUnauthorized"}"#),
            HubAnswer::Unsupported
        );
        assert!(matches!(answer(503, "{}"), HubAnswer::Unavailable(_)));
        assert!(matches!(answer(429, "{}"), HubAnswer::Unavailable(_)));
    }

    fn private(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    #[test]
    fn local_removal_takes_only_the_join() {
        let home = tempfile::tempdir().unwrap();
        let record = MachineCredential {
            credential: "cmm_x".into(),
            machine_id: "machine_1".into(),
            name: "box".into(),
            hub_origin: "https://example.com".into(),
            ..Default::default()
        };
        recovery::write_durable(
            &home.path().join(CREDENTIAL_FILE),
            &serde_json::to_vec(&record).unwrap(),
            true,
        )
        .unwrap();
        crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
        std::fs::write(
            home.path().join("config.json"),
            json!({"defaultHarness": "claude", "meshRelay": {"url": "https://example.com", "credential": "join"}})
                .to_string(),
        )
        .unwrap();
        private(&home.path().join("config.json"));
        let removed = remove_local(home.path()).unwrap();
        assert_eq!(removed, vec!["meshRelay", "credential", "nodeKey"]);
        assert!(!home.path().join(CREDENTIAL_FILE).exists());
        assert!(!home.path().join("node.wg.key").exists());
        let config: Value =
            serde_json::from_slice(&std::fs::read(home.path().join("config.json")).unwrap())
                .unwrap();
        assert!(config.get("meshRelay").is_none(), "{config}");
        assert_eq!(config["defaultHarness"], "claude", "the rest of config.json stays");
        // Again: nothing left to remove, and no error.
        assert!(remove_local(home.path()).unwrap().is_empty());
        // A token-command relay is not the join's and stays.
        std::fs::write(
            home.path().join("config.json"),
            json!({"meshRelay": {"url": "https://example.com", "tokenCommand": ["mint"]}})
                .to_string(),
        )
        .unwrap();
        private(&home.path().join("config.json"));
        assert!(remove_local(home.path()).unwrap().is_empty());
        let config: Value =
            serde_json::from_slice(&std::fs::read(home.path().join("config.json")).unwrap())
                .unwrap();
        assert_eq!(config["meshRelay"]["tokenCommand"][0], "mint");
    }

    /// The node key a cmux link adopted stays, and so does one a running process holds under
    /// the key lock; once neither is so, a leave takes it.
    #[test]
    fn a_leave_never_deletes_an_adopted_or_held_node_key() {
        use cmux_link::key_holder::KeyHolder;
        let record = |home: &Path| {
            let record = MachineCredential {
                credential: "cmm_x".into(),
                machine_id: "machine_1".into(),
                hub_origin: "https://example.com".into(),
                ..Default::default()
            };
            recovery::write_durable(
                &home.join(CREDENTIAL_FILE),
                &serde_json::to_vec(&record).unwrap(),
                true,
            )
            .unwrap();
        };
        let key = |home: &Path| std::fs::read(home.join("node.wg.key")).ok();
        let home = tempfile::tempdir().unwrap();
        crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
        let made = key(home.path());
        assert!(made.is_some());
        // Adopted by the link: kept.
        std::fs::create_dir_all(home.path().join("link")).unwrap();
        std::fs::write(home.path().join("link/key-adopted.json"), b"{}").unwrap();
        record(home.path());
        assert_eq!(remove_local(home.path()).unwrap(), vec!["credential"]);
        assert_eq!(key(home.path()), made);
        std::fs::remove_file(home.path().join("link/key-adopted.json")).unwrap();
        // Held under the key lock (a running link or transport): kept.
        let held = KeyHolder::acquire(home.path()).unwrap();
        record(home.path());
        assert_eq!(remove_local(home.path()).unwrap(), vec!["credential"]);
        assert_eq!(key(home.path()), made);
        drop(held);
        // Neither: it goes.
        record(home.path());
        assert_eq!(remove_local(home.path()).unwrap(), vec!["credential", "nodeKey"]);
        assert_eq!(key(home.path()), None);
    }

    /// Review F1 at c1898fca: a sign-out archives the adoption record with its install
    /// (`key-adopted.<install>.json`); with the link stopped, a leave still keeps the key that
    /// record names, so the install serves it when it signs in again.
    #[test]
    fn a_leave_keeps_a_node_key_an_archived_adoption_names() {
        let key = |home: &Path| std::fs::read(home.join("node.wg.key")).ok();
        let home = tempfile::tempdir().unwrap();
        crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
        let made = key(home.path());
        std::fs::create_dir_all(home.path().join("link")).unwrap();
        let archived = home.path().join("link/key-adopted.inst_a.json");
        std::fs::write(&archived, serde_json::json!({ "key_dir": home.path() }).to_string())
            .unwrap();
        assert!(remove_local(home.path()).unwrap().is_empty());
        assert_eq!(key(home.path()), made);
        // Archived for another home: this home's key goes.
        let other = tempfile::tempdir().unwrap();
        std::fs::write(&archived, serde_json::json!({ "key_dir": other.path() }).to_string())
            .unwrap();
        assert_eq!(remove_local(home.path()).unwrap(), vec!["nodeKey"]);
        assert_eq!(key(home.path()), None);
    }
}
