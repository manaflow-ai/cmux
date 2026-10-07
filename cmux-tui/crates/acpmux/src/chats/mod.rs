//! The device-wide chat index in the daemon (ALL-CHATS-ON-DEVICE). Red
//! step: the API the tests use, with no behavior yet.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_chat_index::RootSpec;

/// An environment lookup by name.
pub type EnvLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Inputs of root discovery.
#[derive(Clone)]
pub struct ChatSources {
    pub home: PathBuf,
    pub acpmux_home: PathBuf,
    pub env: EnvLookup,
    pub launch_roots: Vec<RootSpec>,
    pub user_roots: Vec<RootSpec>,
}

pub fn lookup(
    _key: &str,
    _process: impl Fn(&str) -> Option<String>,
    _login: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    None
}

pub fn refusal(_path: &Path, _home: &Path, _acpmux_home: &Path) -> Option<String> {
    None
}

pub fn launch_roots(_config: &crate::config::Config) -> Vec<RootSpec> {
    Vec::new()
}

impl crate::hub::Hub {
    pub async fn start_chats(self: &Arc<Self>, _sources: ChatSources) -> Result<(), String> {
        Ok(())
    }
}
