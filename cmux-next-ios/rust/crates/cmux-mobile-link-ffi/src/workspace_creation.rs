//! The phone's New Workspace rules: which folders it offers, what a plain tap starts and where,
//! which folders an agent chat may start in, the optimistic row's title, and where the Mac's
//! New Tab rows put a new tab in its pane.
//!
//! These were a Swift copy in CmuxMobileModel's `WorkspaceCreation.swift` (`WorkspaceCreator`
//! `recentDirectories`, `tapStart`, `isProjectFolder`, `defaultDirectory`, `placeholder`,
//! `uniqueTitle`; `RecentDirectories.note`; `NewTabPosition.moveIndex`). Swift now hands its
//! state here and keeps only the UserDefaults store, the backend calls and the UI (Leo,
//! 2026-11-25: "i was wondering why we even have swift at all"; Lawrence, 2026-11-02: "move as
//! much from swift into rust as possible").
//!
//! Every function is pure and linear in its lists (the recents are capped at
//! [`RECENT_LIMIT`]; a pane's tabs are counted once, except the anchor's group walk).

/// The most recent folders the phone keeps and offers per Mac.
pub const RECENT_LIMIT: usize = 5;

/// What a new workspace starts with.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkspaceStart {
    /// The Mac's default: one terminal.
    Terminal,
    /// An agent chat for a harness; "" is the Mac's default agent.
    Agent { harness: String },
    /// A browser tab.
    Browser,
}

/// What one Mac lets the phone choose (the backend's `WorkspaceCreationOptions`).
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceCreationChoices {
    /// The phone may pick the working directory.
    pub directories: bool,
    /// Agent harnesses that can be the first tab.
    pub agents: Vec<String>,
    /// A browser tab can be the first tab.
    pub browser: bool,
    /// A plain tap reuses the last directory used here.
    pub tap_uses_last_directory: bool,
}

/// What a plain tap on New Workspace starts, and in which folder (none: the Mac's default).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceTap {
    pub start: WorkspaceStart,
    pub directory: Option<String>,
}

/// Where the Mac's New Tab rows put a new tab in its pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum NewTabSlot {
    /// New Tab of the Same Kind: where the Mac puts any new tab (after the current one).
    SameKind,
    /// New Tab to the Right.
    AfterCurrent,
    /// New Tab at Start: the first place after the pane's pinned tabs.
    Start,
    /// New Tab at End.
    End,
}

/// The phone's recent folders on a Mac after a workspace was made in `directory`: it first,
/// then the others newest first, without repeats, at most [`RECENT_LIMIT`].
#[uniffi::export]
pub fn workspace_recents_noted(recents: Vec<String>, directory: String) -> Vec<String> {
    let mut list = Vec::with_capacity(RECENT_LIMIT);
    list.push(directory);
    for item in recents {
        if list.len() == RECENT_LIMIT {
            break;
        }
        if item != list[0] {
            list.push(item);
        }
    }
    list
}

/// The folders New Workspace offers on a Mac: the ones used from this phone (`used`, newest
/// first), then the Mac's open workspaces' folders by activity (`seen`), without repeats, at
/// most [`RECENT_LIMIT`]. None when the Mac does not let the phone pick a folder.
#[uniffi::export]
pub fn workspace_recent_directories(directories: bool, used: Vec<String>, seen: Vec<String>) -> Vec<String> {
    if !directories {
        return Vec::new();
    }
    let mut result: Vec<String> = Vec::with_capacity(RECENT_LIMIT);
    for directory in used.into_iter().chain(seen) {
        if result.len() == RECENT_LIMIT {
            break;
        }
        if !result.contains(&directory) {
            result.push(directory);
        }
    }
    result
}

/// What a plain tap on New Workspace makes on a Mac (Aziz, 2026-11-17: an agent chat, not a
/// terminal): a chat with the Mac's default agent (`""`, else the first agent it offers) in
/// its most recent project folder open on the Mac now (`used` from this phone first, then
/// `seen`, the Mac's open folders by activity). A terminal at the Mac's default folder when the
/// Mac offers no agent, does not let the phone pick a folder, or has no such folder: a chat
/// never starts in the home folder, and the Mac refuses a folder it has no workspace in.
#[uniffi::export]
pub fn workspace_tap_start(
    choices: WorkspaceCreationChoices,
    used: Vec<String>,
    seen: Vec<String>,
) -> WorkspaceTap {
    let terminal = WorkspaceTap { start: WorkspaceStart::Terminal, directory: None };
    let harness = if choices.agents.iter().any(String::is_empty) {
        String::new()
    } else if let Some(first) = choices.agents.first() {
        first.clone()
    } else {
        return terminal;
    };
    if !choices.directories {
        return terminal;
    }
    // Only a folder open on the Mac now counts, so a closed recent folder never hides an open one.
    let folder = used.iter().chain(seen.iter()).find(|path| seen.contains(path) && is_project_folder(path));
    match folder {
        Some(folder) => {
            WorkspaceTap { start: WorkspaceStart::Agent { harness }, directory: Some(folder.clone()) }
        }
        None => terminal,
    }
}

/// Whether an agent chat may start in `path`: not the home folder or above it (`~`, `/`,
/// `/Users/<name>`, `/var`, `/var/root`), as the Mac's own guard says. `/Users/Shared` is a
/// project folder.
#[uniffi::export]
pub fn workspace_is_project_folder(path: String) -> bool {
    is_project_folder(&path)
}

fn is_project_folder(path: &str) -> bool {
    let trimmed = path.trim();
    let parts: Vec<&str> = trimmed.split('/').filter(|part| !part.is_empty()).collect();
    if parts.is_empty() || parts == ["~"] {
        return false;
    }
    if trimmed.starts_with('/') {
        if parts == ["var"] || parts == ["var", "root"] {
            return false;
        }
        if parts[0] == "Users" && parts.len() <= 2 && parts.last() != Some(&"Shared") {
            return false;
        }
    }
    true
}

/// The folder a plain New Workspace tap uses on a Mac: the last one used from this phone,
/// else its home (`~`). None when the Mac picks (it lets the phone pick no folder, or its taps
/// go to the Mac's default folder).
#[uniffi::export]
pub fn workspace_default_directory(choices: WorkspaceCreationChoices, used: Vec<String>) -> Option<String> {
    if !choices.directories || !choices.tap_uses_last_directory {
        return None;
    }
    Some(used.into_iter().next().unwrap_or_else(|| "~".to_owned()))
}

/// Whether a Mac with these choices can start a workspace this way (a terminal always).
#[uniffi::export]
pub fn workspace_start_offered(choices: WorkspaceCreationChoices, start: WorkspaceStart) -> bool {
    match start {
        WorkspaceStart::Terminal => true,
        WorkspaceStart::Agent { harness } => choices.agents.contains(&harness),
        WorkspaceStart::Browser => choices.browser,
    }
}

/// The optimistic row's title: the folder's last component, unique among the Mac's
/// workspace titles ("cmux", then "cmux 2", "cmux 3", ...). "New Workspace" for no folder,
/// the home folder or the root.
#[uniffi::export]
pub fn workspace_placeholder_title(directory: Option<String>, existing: Vec<String>) -> String {
    workspace_unique_title(directory_title(directory.as_deref()), existing)
}

fn directory_title(directory: Option<&str>) -> String {
    const UNTITLED: &str = "New Workspace";
    let Some(directory) = directory else { return UNTITLED.to_owned() };
    if directory == "~" || directory == "/" {
        return UNTITLED.to_owned();
    }
    // As NSString's lastPathComponent: trailing slashes go; a path of only slashes is "/".
    let stripped = directory.trim_end_matches('/');
    let last = if stripped.is_empty() && !directory.is_empty() {
        "/"
    } else {
        stripped.rsplit('/').next().unwrap_or("")
    };
    if last.is_empty() || last == "~" { UNTITLED.to_owned() } else { last.to_owned() }
}

/// `base`, or `base 2`, `base 3`, ...: the first one no title in `existing` has.
#[uniffi::export]
pub fn workspace_unique_title(base: String, existing: Vec<String>) -> String {
    let taken: std::collections::HashSet<&str> = existing.iter().map(String::as_str).collect();
    if !taken.contains(base.as_str()) {
        return base;
    }
    (2..).map(|n| format!("{base} {n}")).find(|title| !taken.contains(title.as_str())).unwrap_or(base)
}

/// The optimistic agent tab's title for a harness: "Agent Chat" for the Mac's default agent,
/// "Claude", "Codex", else the harness capitalized ("opencode" is "Opencode").
#[uniffi::export]
pub fn workspace_agent_tab_title(harness: String) -> String {
    match harness.as_str() {
        "" => "Agent Chat".to_owned(),
        "claude" => "Claude".to_owned(),
        "codex" => "Codex".to_owned(),
        other => capitalized(other),
    }
}

/// Each word's first letter upper case, the rest lower case (Foundation's `capitalized`:
/// a word starts after anything that is not a letter or digit).
fn capitalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut starts_word = true;
    for ch in text.chars() {
        if ch.is_alphanumeric() {
            if starts_word {
                out.extend(ch.to_uppercase());
            } else {
                out.extend(ch.to_lowercase());
            }
            starts_word = false;
        } else {
            out.push(ch);
            starts_word = true;
        }
    }
    out
}

/// The `move-tab` insertion index that puts a tab now at `from` in a pane whose places are
/// `pinned` (one flag per tab, in order) and `groups` (each tab's group id, none for none;
/// empty for no groups) at `slot`, beside the tab at `anchor`. None when it is in place
/// already. As the Mac's `NewTabSlot`: after the anchor goes past the anchor's whole tab group
/// and never among pinned tabs; at start is the first place after the pinned tabs. The daemon
/// reads the index as an insertion point in the current list, one past for a forward move.
#[uniffi::export]
pub fn new_tab_move_index(
    slot: NewTabSlot,
    from: u32,
    anchor: u32,
    pinned: Vec<bool>,
    groups: Vec<Option<String>>,
) -> Option<u32> {
    let (from, anchor) = (from as usize, anchor as usize);
    let count = pinned.len();
    if count <= 1 || from >= count || anchor >= count || anchor == from {
        return None;
    }
    // The places without the new tab, where the final index is counted.
    let others: Vec<usize> = (0..count).filter(|&index| index != from).collect();
    let pinned_count = others.iter().take_while(|&&index| pinned[index]).count();
    let target = match slot {
        NewTabSlot::SameKind | NewTabSlot::AfterCurrent => {
            let mut at = others.iter().position(|&index| index == anchor)?;
            if let Some(Some(group)) = groups.get(anchor) {
                while at + 1 < others.len()
                    && groups.get(others[at + 1]).is_some_and(|g| g.as_ref() == Some(group))
                {
                    at += 1;
                }
            }
            (at + 1).max(pinned_count)
        }
        NewTabSlot::Start => pinned_count,
        NewTabSlot::End => count - 1,
    };
    let clamped = target.min(count - 1);
    if clamped == from {
        return None;
    }
    let index = if clamped > from { clamped + 1 } else { clamped };
    u32::try_from(index).ok()
}

#[cfg(test)]
#[path = "workspace_creation_tests.rs"]
mod tests;
