//! What the chat index reads from the daemon: the user's home, acpmux's own
//! home, the login environment, and the store roots of harness profiles.
//! Each piece can be replaced, so tests run on synthetic homes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_chat_index::{AdapterKind, RootSpec};

/// An environment lookup by name.
pub type EnvLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Inputs of root discovery.
#[derive(Clone)]
pub struct ChatSources {
    /// The user's home folder.
    pub home: PathBuf,
    /// This daemon's home (`config::home()`): the cache and the recorded roots live here.
    pub acpmux_home: PathBuf,
    /// The environment that names harness homes (`login_var` in the daemon).
    pub env: EnvLookup,
    /// Store roots that harness profiles set in their launch env.
    pub launch_roots: Vec<RootSpec>,
    /// Roots the user added (Settings, `agents.chats.roots`).
    pub user_roots: Vec<RootSpec>,
}

impl ChatSources {
    /// The daemon's real sources. None when the home folder is unknown.
    pub fn daemon(config: &crate::config::Config) -> Option<Self> {
        Some(Self {
            home: dirs::home_dir()?,
            acpmux_home: crate::config::home(),
            env: Arc::new(login_var),
            launch_roots: launch_roots(config),
            user_roots: Vec::new(),
        })
    }

    /// Why `path` is never a chat root, or None.
    pub fn refusal(&self, path: &Path) -> Option<String> {
        refusal(path, &self.home, &self.acpmux_home)
    }
}

/// A variable from the daemon's own environment, else from the imported
/// login shell environment. Under launchd the daemon's environment lacks
/// what `.zshenv` exports (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
pub fn login_var(key: &str) -> Option<String> {
    lookup(key, |key| std::env::var(key).ok(), crate::login_env::var)
}

/// `login_var` with both environments given. An empty value counts as unset.
pub fn lookup(
    key: &str,
    process: impl Fn(&str) -> Option<String>,
    login: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    process(key).filter(|v| !v.is_empty()).or_else(|| login(key).filter(|v| !v.is_empty()))
}

/// Why `path` is never a chat root: inside an acpmux daemon home (other
/// tags' daemons), the Chief home or cmux's own app data (Chief chats live
/// in Home), or inside a privacy-protected folder. The spelling is checked
/// before anything reads the path.
pub fn refusal(path: &Path, home: &Path, acpmux_home: &Path) -> Option<String> {
    let excluded = [
        (home.join(".acpmux"), "an acpmux daemon home"),
        (acpmux_home.to_path_buf(), "an acpmux daemon home"),
        (home.join(".cmux/chief"), "the Chief home"),
        (home.join("Library/Application Support/cmux"), "cmux's own app data"),
    ];
    for (dir, what) in excluded {
        if path.starts_with(&dir) {
            return Some(format!("{} is inside {what}; its chats are not listed", path.display()));
        }
    }
    crate::protected_folders::refusal_in(path, Some(home))
}

/// Store roots that harness profiles and family defaults set in their
/// launch env (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`): every chat an acpmux
/// spawn writes lands in one of them.
pub fn launch_roots(config: &crate::config::Config) -> Vec<RootSpec> {
    let envs = config
        .harnesses
        .values()
        .map(|profile| &profile.env)
        .chain(config.defaults.values().map(|defaults| &defaults.env));
    let mut roots: Vec<RootSpec> = Vec::new();
    for env in envs {
        for spec in roots_in_env(env) {
            if !roots.contains(&spec) {
                roots.push(spec);
            }
        }
    }
    roots
}

fn roots_in_env(env: &BTreeMap<String, String>) -> Vec<RootSpec> {
    let mut out = Vec::new();
    let mut add = |key: &str, harness: AdapterKind, sub: Option<&str>| {
        let Some(dir) = env.get(key).map(PathBuf::from).filter(|dir| dir.is_absolute()) else {
            return;
        };
        let path = sub.map_or_else(|| dir.clone(), |sub| dir.join(sub));
        out.push(RootSpec { harness, path, label: None });
    };
    add("CLAUDE_CONFIG_DIR", AdapterKind::ClaudeCode, Some("projects"));
    add("CODEX_HOME", AdapterKind::Codex, None);
    out
}
