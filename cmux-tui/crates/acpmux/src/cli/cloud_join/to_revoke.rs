//! What a sign-out still has to revoke at the hub, and the marks that say whose a hub's revoke
//! was. Each is a file of its own, named by what it is about, so a second sign-out never
//! overwrites a first one's entry before it is handled: one replaceable stale-row file and one
//! replaceable retired-proposal file let a second failed revoke drop the first, whose credential
//! then stayed live at the hub for good.
//!
//! - [`QUEUE`]: one entry per credential (or hub row) not revoked yet, written durably before
//!   what it replaces goes, and removed only once the hub says it is revoked or gone.
//! - [`REVOKED`]: one mark per hub that had revoked this machine before its sign-out, so a join
//!   on another hub never ends this hub's mark.
//! - [`SELF_REVOKE`]: the joined credential this box's sign-out is revoking (its hash), written
//!   before the revoke is sent, so a revoke the hub committed before this box stopped is read as
//!   this box's own when asked again, never as someone else's.
//!
//! The caller holds the join lock.
use super::*;
use std::path::{Path, PathBuf};

/// The credentials and hub rows a sign-out has not revoked yet, one file each.
const QUEUE: &str = "machine-join.to-revoke";
/// The hubs that revoked this machine before its sign-out, one file each.
const REVOKED: &str = "machine-join.revoked";
/// The joined credential (its hash) this box's sign-out is revoking.
const SELF_REVOKE: &str = "machine-join.self-revoke.json";

/// One hub row of this box, or one credential of it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Row {
    /// Empty for a join proposal's credential: the hub never named its row here.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub machine_id: String,
    pub hub_origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_fingerprint: Option<String>,
    /// With it, the revoke is asked with the credential itself; without, by the row's id with
    /// the person's token at the next sign-in. Never sent anywhere else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

impl Row {
    /// `record`'s row; with `credential`, with its credential.
    pub(super) fn of(record: &MachineCredential, credential: bool) -> Self {
        Self {
            machine_id: record.machine_id.clone(),
            hub_origin: record.hub_origin.clone(),
            host_fingerprint: record.host_fingerprint.clone(),
            credential: credential.then(|| record.credential.clone()),
        }
    }

    /// The record the machine's self-revoke sends, when the row carries its credential.
    pub(super) fn as_record(&self) -> Option<MachineCredential> {
        Some(MachineCredential {
            credential: self.credential.clone()?,
            machine_id: self.machine_id.clone(),
            hub_origin: self.hub_origin.clone(),
            host_fingerprint: self.host_fingerprint.clone(),
            ..Default::default()
        })
    }

    /// Whether the row is this box's (`current`) on `hub`.
    pub(super) fn on(&self, hub: &str, current: Option<&str>) -> bool {
        self.host_fingerprint.as_deref() == current
            && origin(Some(self.hub_origin.clone())).ok().as_deref() == Some(hub)
    }

    /// Its queue entry's name: one per credential, or per hub row when it carries none.
    fn queue_name(&self) -> String {
        let id = match &self.credential {
            Some(credential) => format!("credential\n{credential}"),
            None => format!("row\n{}\n{}", hub_key(&self.hub_origin), self.machine_id),
        };
        format!("{}.json", crate::sha256::sha256_hex(id.as_bytes()))
    }
}

/// A hub origin as its marks are named by.
fn hub_key(hub: &str) -> String {
    origin(Some(hub.to_owned())).unwrap_or_else(|_| hub.to_owned())
}

fn hub_file(hub: &str) -> String {
    format!("{}.json", crate::sha256::sha256_hex(hub_key(hub).as_bytes()))
}

fn put(home: &Path, dir: &str, name: &str, row: &Row) -> Result<()> {
    let dir = home.join(dir);
    crate::config::private_state_dir(&dir)?;
    recovery::write_durable(&dir.join(name), &serde_json::to_vec(row)?, true)
}

/// An entry's file: a write's temporary file is not one.
fn entry_file(path: &Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    !name.starts_with('.') && name.ends_with(".json")
}

/// The rows in `home`'s `dir`. One that does not parse is dropped (nothing could revoke with
/// it); one that cannot be opened now is kept for the next read.
fn rows(home: &Path, dir: &str) -> Result<Vec<(PathBuf, Row)>> {
    let entries = match std::fs::read_dir(home.join(dir)) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    let mut rows = Vec::new();
    for entry in entries {
        let path = entry?.path();
        if !entry_file(&path) {
            continue;
        }
        let Ok(file) = crate::config::private_state_file(&path) else { continue };
        match serde_json::from_reader::<_, Row>(file) {
            Ok(row) => rows.push((path, row)),
            Err(e) => {
                tracing::warn!("sign-out leave: an unreadable entry is dropped: {e:#}");
                remove(&path)?;
            }
        }
    }
    Ok(rows)
}

/// Removes one entry, durably.
pub(super) fn remove(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => recovery::sync_ancestors(path.parent().ok_or_else(store_error)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

/// Queues `row` to be revoked, beside every one queued before it.
pub(super) fn queue(home: &Path, row: &Row) -> Result<()> {
    put(home, QUEUE, &row.queue_name(), row)
}

/// Every queued row, with its file.
pub(super) fn queued(home: &Path) -> Result<Vec<(PathBuf, Row)>> {
    rows(home, QUEUE)
}

/// Whether anything is queued (cheap: nothing is parsed).
pub(super) fn any_queued(home: &Path) -> bool {
    std::fs::read_dir(home.join(QUEUE)).is_ok_and(|mut entries| {
        entries.any(|entry| entry.is_ok_and(|entry| entry_file(&entry.path())))
    })
}

/// Marks that someone had revoked `record` at its hub before this box's sign-out.
pub(super) fn mark_revoked(home: &Path, record: &MachineCredential) -> Result<()> {
    put(home, REVOKED, &hub_file(&record.hub_origin), &Row::of(record, false))
}

/// Whether `hub` revoked this box (`current`) before its sign-out.
pub(super) fn revoked_on(home: &Path, hub: &str, current: Option<&str>) -> bool {
    let path = home.join(REVOKED).join(hub_file(hub));
    crate::config::private_state_file(&path)
        .ok()
        .and_then(|file| serde_json::from_reader::<_, Row>(file).ok())
        .is_some_and(|row| row.on(hub, current))
}

/// Ends `hub`'s revoked mark: the person joined this machine there again themselves. Another
/// hub's mark stays.
pub(super) fn clear_revoked(home: &Path, hub: &str) {
    if let Err(e) = remove(&home.join(REVOKED).join(hub_file(hub))) {
        tracing::warn!("sign-in enroll: a revoked mark stayed: {e:#}");
    }
}

fn credential_hash(record: &MachineCredential) -> String {
    crate::sha256::sha256_hex(record.credential.as_bytes())
}

/// Marks that this box's sign-out is about to revoke `record`'s credential, durably, before the
/// revoke is sent.
pub(super) fn mark_self_revoke(home: &Path, record: &MachineCredential) -> Result<()> {
    let mark = json!({"credentialSha256": credential_hash(record)});
    recovery::write_durable(&home.join(SELF_REVOKE), &serde_json::to_vec(&mark)?, true)
}

/// Whether this box's sign-out was revoking `record`'s credential: what the hub then says
/// about it is that sign-out's doing.
pub(super) fn self_revoking(home: &Path, record: &MachineCredential) -> bool {
    crate::config::private_state_file(&home.join(SELF_REVOKE))
        .ok()
        .and_then(|file| serde_json::from_reader::<_, Value>(file).ok())
        .is_some_and(|mark| {
            mark.get("credentialSha256").and_then(Value::as_str)
                == Some(credential_hash(record).as_str())
        })
}

/// Ends the self-revoke mark: its leave finished, or a sign-in kept the join it was leaving.
pub(super) fn clear_self_revoke(home: &Path) {
    if let Err(e) = remove(&home.join(SELF_REVOKE)) {
        tracing::warn!("sign-out leave: the self-revoke mark stayed: {e:#}");
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn row(credential: Option<&str>, machine_id: &str) -> Row {
        Row {
            machine_id: machine_id.to_owned(),
            hub_origin: "https://hub.example".to_owned(),
            host_fingerprint: Some("box-a".to_owned()),
            credential: credential.map(str::to_owned),
        }
    }

    #[test]
    fn a_second_entry_never_replaces_the_first() {
        let home = tempfile::tempdir().unwrap();
        let (a, b) = (row(Some("cmm_a"), "machine_a"), row(Some("cmm_b"), "machine_b"));
        queue(home.path(), &a).unwrap();
        queue(home.path(), &b).unwrap();
        // The same credential again is the same entry.
        queue(home.path(), &a).unwrap();
        let mut rows: Vec<Row> =
            queued(home.path()).unwrap().into_iter().map(|(_, row)| row).collect();
        rows.sort_by(|x, y| x.machine_id.cmp(&y.machine_id));
        assert_eq!(rows, vec![a, b]);
        // A write's leftover temporary file is not an entry.
        for (path, _) in queued(home.path()).unwrap() {
            remove(&path).unwrap();
        }
        std::fs::write(home.path().join(QUEUE).join(".machine-join-x.tmp"), b"{}").unwrap();
        assert!(!any_queued(home.path()));
    }

    #[test]
    fn each_hub_keeps_its_own_revoked_mark() {
        let home = tempfile::tempdir().unwrap();
        let on = |hub: &str| MachineCredential {
            machine_id: "machine".into(),
            hub_origin: hub.into(),
            host_fingerprint: Some("box-a".into()),
            ..Default::default()
        };
        mark_revoked(home.path(), &on("https://hub.example")).unwrap();
        mark_revoked(home.path(), &on("https://other.example")).unwrap();
        clear_revoked(home.path(), "https://other.example");
        assert!(revoked_on(home.path(), "https://hub.example", Some("box-a")));
        assert!(!revoked_on(home.path(), "https://other.example", Some("box-a")));
        assert!(!revoked_on(home.path(), "https://hub.example", Some("box-b")));
    }
}
