//! How a chat opens again (ALL-CHATS-ON-DEVICE S5). Red step: no behavior.

use std::path::{Path, PathBuf};

use cmux_chat_index::IndexedChat;
use serde_json::Value;

/// A configured profile and the harness stores it resumes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoreProfile {
    pub name: String,
    pub family: String,
    pub claude: Option<PathBuf>,
    pub codex: Option<PathBuf>,
}

pub fn store_profiles(
    _config: &crate::config::Config,
    _homes: &crate::adopt::HarnessHomes,
) -> Vec<StoreProfile> {
    Vec::new()
}

pub fn plan_open(
    _chat: &IndexedChat,
    _profiles: &[StoreProfile],
    _given_cwd: Option<&Path>,
    _home: &Path,
) -> Result<Value, String> {
    Err("not yet".into())
}
