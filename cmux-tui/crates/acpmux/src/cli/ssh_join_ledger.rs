//! Which machine each Door A join token went to, kept on the computer that ran the join
//! (`ssh-joins.json` in acpmux's home): the ssh destination and the far machine's ssh host key.
//!
//! A re-add with the same name on the same machine replaces the record an earlier add left (Door A
//! timing run, huge-blue/doora-timing, 2026-11-16: a failed first add of doora-vm-1 left a second
//! `doora-vm-1`, and `cmux chat --on doora-vm-1` refused "2 joined machines are named doora-vm-1").
//! The hub's list names a machine by its label and host name, which two VMs share; only this
//! ledger says which token went to which box. A token is recorded as soon as it is minted, so an
//! add that fails after the join script redeemed it is still known.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const VERSION: u32 = 1;
/// The most tokens kept: the oldest go first.
const KEEP: usize = 128;

/// Where one join token went.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub join_token_id: String,
    /// The ssh destination as the person named it (`HOST`, `USER@HOST`, an alias).
    pub host: String,
    /// [`super::host_key_of`]: the far machine's ssh host key, `SHA256:...`.
    pub host_key: String,
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    version: u32,
    joins: Vec<Entry>,
}

/// The ledger file in acpmux's home.
pub fn path() -> PathBuf {
    crate::machine_record::state_dir().join("ssh-joins.json")
}

fn read(path: &Path) -> Vec<Entry> {
    crate::peer_last_good::read_json::<File>(path)
        .filter(|file| file.version == VERSION)
        .map(|file| file.joins)
        .unwrap_or_default()
}

/// Records where `entry`'s token went (a token named again replaces its entry).
pub fn remember(path: &Path, entry: Entry) -> std::io::Result<()> {
    let mut joins = read(path);
    joins.retain(|known| known.join_token_id != entry.join_token_id);
    joins.push(entry);
    let extra = joins.len().saturating_sub(KEEP);
    joins.drain(..extra);
    crate::peer_last_good::write_json(path, &File { version: VERSION, joins })
}

/// Where the token `join_token_id` went, if this computer minted it.
pub fn find(path: &Path, join_token_id: &str) -> Option<Entry> {
    read(path).into_iter().find(|entry| entry.join_token_id == join_token_id)
}
