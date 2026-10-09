//! Spaces (the daemon's `profiles-v1` rooms) and which workspaces each one
//! shows. Not implemented yet.

use serde_json::Value;

/// The capability of the space (profile) commands and `personal-changed`.
pub const PROFILES_CAPABILITY: &str = "profiles-v1";
/// The space that always exists.
pub const DEFAULT_SPACE: &str = "default";

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct WorkspaceRef {
    pub session: String,
    pub key: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Space {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub theme: Option<String>,
    pub browser_profile_id: Option<String>,
    pub default_session_id: Option<String>,
    pub defaults: Option<Value>,
    pub follows: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Spaces {
    pub revision: u64,
    pub spaces: Vec<Space>,
}

impl Spaces {
    pub fn from_personal(_personal: &Value) -> Result<Self, String> {
        Err("not implemented".into())
    }
    pub fn following_all(_sessions: &[String]) -> Self {
        Self::default()
    }
    pub fn space(&self, _id: &str) -> Option<&Space> {
        None
    }
    pub fn position(&self, _id: &str) -> Option<usize> {
        None
    }
    pub fn spaces_of(&self, _workspace: &WorkspaceRef) -> Vec<String> {
        Vec::new()
    }
    pub fn contains(&self, _workspace: &WorkspaceRef, _space: &str) -> bool {
        false
    }
    pub fn closes(&self, _workspace: &WorkspaceRef, _deleting: &str) -> bool {
        false
    }
    pub fn pin(&mut self, _workspace: WorkspaceRef, _space: &str) {}
    pub fn remove_space(&mut self, _space: &str, _move_pins_to: Option<&str>) {}
}
