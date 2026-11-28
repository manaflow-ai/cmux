//! Spaces: the home session's switchable sets of workspaces
//! (plans/cmux-next/data-model.md 3). The wire calls a space a profile
//! (`profiles-v1`, `create-profile`, `list-personal` `profiles`).
//!
//! [`Spaces::from_personal`] reads the spaces and pins of a `list-personal`
//! reply; the membership rule (data-model.md 3.2, cmux-next
//! `RoomMembership`) says which spaces show a workspace: the space it is
//! pinned to, else every space that follows its session, else `default`, so
//! no workspace is ever unreachable. Which space a window shows is the
//! frontend's (its window record), not this crate's.

use serde_json::Value;
use std::collections::HashMap;

/// The capability of the space (profile) commands and `personal-changed`.
pub const PROFILES_CAPABILITY: &str = "profiles-v1";
/// The space that always exists (the daemon refuses to delete it).
pub const DEFAULT_SPACE: &str = "default";

/// A workspace qualified by the session that owns it (the session's
/// `registry_id` and the workspace's stable key).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct WorkspaceRef {
    pub session: String,
    pub key: String,
}

/// One space (`list-personal` `profiles[]`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Space {
    /// `default` or `prof_<32 hex>`.
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    /// One emoji or an SF Symbol name.
    pub icon: Option<String>,
    pub theme: Option<String>,
    /// The space's default browser profile (none: `default`).
    pub browser_profile_id: Option<String>,
    /// Where New Workspace creates (none: the home session).
    pub default_session_id: Option<String>,
    /// `{"cwd", "env"}` for new terminals, applied by the frontend.
    pub defaults: Option<Value>,
    /// The sessions whose unpinned workspaces the space shows.
    pub follows: Vec<String>,
}

/// The spaces in order and the workspace pins.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Spaces {
    /// `personal_revision` of the read.
    pub revision: u64,
    /// In the daemon's order (`index`).
    pub spaces: Vec<Space>,
    /// The one space each pinned workspace is pinned to.
    pub pins: HashMap<WorkspaceRef, String>,
}

fn opt_string(row: &Value, field: &str) -> Result<Option<String>, String> {
    match row.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(other) => Err(format!("{field}: not a string: {other}")),
    }
}

fn string(row: &Value, field: &str) -> Result<String, String> {
    opt_string(row, field)?.ok_or_else(|| format!("{field}: missing"))
}

fn rows<'a>(personal: &'a Value, field: &str) -> Result<&'a [Value], String> {
    match personal.get(field) {
        None | Some(Value::Null) => Ok(&[]),
        Some(Value::Array(rows)) => Ok(rows),
        Some(other) => Err(format!("{field}: not an array: {other}")),
    }
}

impl Spaces {
    /// Reads a `list-personal` reply. Unknown fields are ignored; a reply
    /// without `pins` (an older daemon) has none.
    pub fn from_personal(personal: &Value) -> Result<Self, String> {
        let revision = personal.get("personal_revision").and_then(Value::as_u64).unwrap_or(0);
        let mut indexed = Vec::new();
        for row in rows(personal, "profiles")? {
            let follows = match row.get("follows") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(ids)) => ids
                    .iter()
                    .map(|id| id.as_str().map(str::to_string).ok_or("follows: not a string"))
                    .collect::<Result<_, _>>()?,
                Some(other) => return Err(format!("follows: not an array: {other}")),
            };
            let space = Space {
                id: string(row, "id")?,
                name: opt_string(row, "name")?.unwrap_or_default(),
                color: opt_string(row, "color")?,
                icon: opt_string(row, "icon")?,
                theme: opt_string(row, "theme")?,
                browser_profile_id: opt_string(row, "browser_profile_id")?,
                default_session_id: opt_string(row, "default_session_id")?,
                defaults: row.get("defaults").filter(|v| !v.is_null()).cloned(),
                follows,
            };
            let index = row.get("index").and_then(Value::as_u64).unwrap_or(u64::MAX);
            indexed.push((index, space));
        }
        // Stable: equal indexes keep the reply's order.
        indexed.sort_by_key(|(index, _)| *index);
        let mut pins = HashMap::new();
        for row in rows(personal, "pins")? {
            let workspace = WorkspaceRef {
                session: string(row, "session_id")?,
                key: string(row, "workspace_key")?,
            };
            pins.insert(workspace, string(row, "profile")?);
        }
        Ok(Self { revision, spaces: indexed.into_iter().map(|(_, s)| s).collect(), pins })
    }

    /// Spaces for a daemon without personal state (no `profiles-v1`):
    /// `default` follows every session.
    pub fn following_all(sessions: &[String]) -> Self {
        let default = Space {
            id: DEFAULT_SPACE.to_string(),
            name: String::new(),
            color: None,
            icon: None,
            theme: None,
            browser_profile_id: None,
            default_session_id: None,
            defaults: None,
            follows: sessions.to_vec(),
        };
        Self { revision: 0, spaces: vec![default], pins: HashMap::new() }
    }

    pub fn space(&self, id: &str) -> Option<&Space> {
        self.spaces.iter().find(|s| s.id == id)
    }

    /// The space's place in the order.
    pub fn position(&self, id: &str) -> Option<usize> {
        self.spaces.iter().position(|s| s.id == id)
    }

    /// The spaces that show `workspace`, in space order; never empty. A pin
    /// decides alone (even to a space this read does not list).
    pub fn spaces_of(&self, workspace: &WorkspaceRef) -> Vec<String> {
        if let Some(pinned) = self.pins.get(workspace) {
            return vec![pinned.clone()];
        }
        let followers: Vec<String> = self
            .spaces
            .iter()
            .filter(|s| s.follows.contains(&workspace.session))
            .map(|s| s.id.clone())
            .collect();
        if followers.is_empty() { vec![DEFAULT_SPACE.to_string()] } else { followers }
    }

    pub fn contains(&self, workspace: &WorkspaceRef, space: &str) -> bool {
        self.spaces_of(workspace).iter().any(|s| s == space)
    }

    /// Whether deleting `space` (with no `move_to`) closes `workspace`: no
    /// other space shows it, and `space` is not `default` (the daemon's
    /// `room_archive::closing_keys`). The daemon also never closes the home
    /// workspace or another session's; callers filter those.
    pub fn closes(&self, workspace: &WorkspaceRef, deleting: &str) -> bool {
        deleting != DEFAULT_SPACE && self.spaces_of(workspace) == [deleting]
    }

    /// Pins `workspace` to `space` (`pin-workspace`, Move Workspace to
    /// Space), replacing any other pin.
    pub fn pin(&mut self, workspace: WorkspaceRef, space: &str) {
        self.pins.insert(workspace, space.to_string());
    }

    /// `space` is deleted: its pins go to `move_pins_to`, or are removed (the
    /// workspaces return to their followers), and it follows nothing.
    pub fn remove_space(&mut self, space: &str, move_pins_to: Option<&str>) {
        self.spaces.retain(|s| s.id != space);
        match move_pins_to {
            Some(target) => {
                for pinned in self.pins.values_mut().filter(|p| *p == space) {
                    *pinned = target.to_string();
                }
            }
            None => self.pins.retain(|_, pinned| pinned != space),
        }
    }
}
