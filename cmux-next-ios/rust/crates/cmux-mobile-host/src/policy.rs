//! The `daemon` service's line filter: a Rust mirror of
//! `Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`.
//! Keep the two lists identical; a command the daemon adds later is refused
//! until it is reviewed and added in both places.

use std::collections::{BTreeSet, HashSet};
use std::sync::LazyLock;

use serde_json::{Map, Value, json};

/// Largest request line the phone may send (the daemon's WebSocket frame cap).
pub const MAXIMUM_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Commands a phone may send.
pub static ALLOWED_COMMANDS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    [
        // Session and discovery (read-only).
        "identify",
        "ping",
        "server-stats",
        "set-client-info",
        "list-clients",
        "list-workspaces",
        "list-workspace-groups",
        "list-tab-groups",
        "list-saved-tab-groups",
        "list-notifications",
        // The person's own sidebar order (`profiles-v1`): read only.
        "list-personal",
        "list-agents",
        "list-terminals",
        "resolve-terminal",
        "process-info",
        "machine-usage",
        "machine-listening-tcp",
        "ids",
        "export-layout",
        "subscribe",
        "terminal-events",
        "wait-for",
        // Terminal streams and input.
        "attach-surface",
        "vt-state",
        "read-screen",
        "read-scrollback",
        "scroll-surface",
        "send",
        "send-key",
        "copy",
        "clear-history",
        "set-terminal-idle-policy",
        "get-cell-pixels",
        "set-cell-pixels",
        // Geometry: per-client leases, released when the phone goes away.
        "set-client-sizing",
        "resize-surface",
        "release-surface-size",
        "resize-attached-view",
        "release-attached-view-size",
        "detach-attached-view",
        // Shared sizing: the size state, the phone's own activity, and this
        // Mac's sizing policy (`host-size-policy-v1`; the Mac-wide preference
        // only, never `set-size-policy`).
        "get-size-state",
        "note-size-activity",
        "get-host-size-policy",
        "set-host-size-policy",
        // Per-client focus (never moves the Mac's view).
        "client-focus",
        "report-focus",
        // Topology.
        "create-workspace",
        "new-workspace",
        "rename-workspace",
        "close-workspace",
        "move-workspace",
        "set-workspace-metadata",
        "create-workspace-group",
        "update-workspace-group",
        "delete-workspace-group",
        "move-workspace-group",
        "move-workspace-to-group",
        // The person's own sidebar order: a workspace's place only
        // (`PERSONAL_WORKSPACE_FIELDS`).
        "set-personal-workspace",
        "create-terminal",
        "new-tab",
        "new-screen",
        "new-pane",
        "new-pane-right",
        "split",
        "set-ratio",
        "set-split-ratio",
        "set-viewport-pane-width",
        "undo-layout",
        "pane-neighbor",
        "focus-direction",
        "swap-pane",
        "zoom-pane",
        "close-surface",
        "close-pane",
        "close-screen",
        "close-terminal",
        "rename-pane",
        "rename-surface",
        "rename-screen",
        "focus-pane",
        "select-tab",
        "select-screen",
        "select-workspace",
        "move-tab",
        "move-terminal",
        "set-tab-pinned",
        "move-tab-to-workspace",
        "move-tab-to-split",
        "move-tab-to-column",
        "move-tab-to-new-workspace",
        "create-tab-group",
        "update-tab-group",
        "add-tabs-to-tab-group",
        "remove-tabs-from-tab-group",
        "move-tab-group",
        "move-tab-group-to-split",
        "move-tab-group-to-column",
        "move-tab-group-to-new-workspace",
        "ungroup-tab-group",
        "close-tab-group",
        "save-tab-group",
        "unsave-tab-group",
        // Saved tab groups: the saved id (and, to reopen, a pane) only
        // (`creation_fields`, `saved_group_refusal`). Reopen restarts the
        // saved terminals as the person's login shell in their saved folder,
        // on this Mac (cmux-next-ios/SECURITY.md "Reopen Saved Tab Group").
        "delete-saved-tab-group",
        "reopen-saved-tab-group",
        "ack-tab-notifications",
        "notify",
        // A reply to a terminal notification: its id and the person's text
        // only (`notification_reply_refusal`). hostd answers it itself
        // (`mailbox_apply::reply_to_notification`); the daemon never sees it.
        "notification-reply",
        // Restart Shell: a dead terminal tab of the person's gets its shell
        // again, on this Mac, under the same terminal id; the surface only
        // (`creation_fields`). Verified live (cmux-next-ios/SECURITY.md "Restart Shell").
        "restart-tab",
        // Agent chat tabs: only an acpmux session tab of this Mac's own
        // acpmux, checked below (`agent_tab_verdict`).
        "new-conversation-tab",
        // Browser tabs.
        "new-browser-tab",
        "browser-frame-presented",
        "browser-mouse",
        "browser-mouse-guarded",
        "browser-wheel",
        "browser-wheel-guarded",
        "browser-key",
        "browser-key-press",
        "browser-insert-text",
        "browser-navigate",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "browser-activate",
        // Frontend projections: guarded per subject below.
        "get-frontend-projection",
        "put-frontend-projection",
    ]
    .into_iter()
    .collect()
});

/// Fields a phone may set on `set-personal-workspace`: which of the person's
/// workspaces and its place in their sidebar. Never its `group`, browser
/// profile, `theme` or `remote_localhost` (which opens the Mac's loopback to a
/// remote workspace's browser).
const PERSONAL_WORKSPACE_FIELDS: &[&str] = &["session_id", "workspace_key", "index"];

/// `cmux.protocol/2` operations a phone may send on the daemon lane, each with
/// the params it may carry. Deny by default: every other operation (the
/// daemon's whole resource API) is refused before it reaches the socket.
/// - `notification.clear`: Clear All Notifications, the Mac's own action, on
///   this session's ledger only (no `terminal_id`, no revision guard).
/// - `sidebar_layout.get`: the person's sidebar layout, to show their pins.
/// - `sidebar_layout.update`: Unpin Workspace only, an `item.remove` of a
///   pinned item the Mac minted (`itm_` + 16 base32 characters); never a
///   built-in item, a section, a reset or an added item.
/// - `workspace_group.create`: a new personal workspace group with a name, a
///   palette color and the room it shows in (cmux-next-ios/SECURITY.md "Workspace
///   groups"). Never its id, place (`index`), icon or pin.
/// - `workspace_group.update`: Rename Group…, its color, Collapse / Expand, of
///   a group whose workspaces are all this session's (`Ownership::OwnGroup`).
///   Never `room` (which pins every member to another room), `top_index`,
///   `icon` or `pinned`.
/// - `workspace_group.delete`: Ungroup Workspaces / Delete Group (the
///   workspaces stay open), same ownership.
/// - `workspace.place`: Move Workspace to Group / Remove Workspace from Group,
///   a live workspace of this session (`ws_…`) into one of those groups or out
///   (`group: null`); never its `index`.
const ALLOWED_RESOURCE_OPERATIONS: &[(&str, &[&str])] = &[
    ("notification.clear", &["machine", "session"]),
    ("sidebar_layout.get", &["machine", "session"]),
    ("sidebar_layout.update", &["machine", "session", "op"]),
    ("workspace_group.create", &["machine", "session", "name", "color", "room"]),
    ("workspace_group.update", &["machine", "session", "workspace_group", "name", "color", "collapsed"]),
    ("workspace_group.delete", &["machine", "session", "workspace_group"]),
    ("workspace.place", &["machine", "session", "workspace", "group"]),
];

/// The group colors the Mac's menus offer (cmux-next `GroupColor`).
const GROUP_COLORS: &[&str] = &["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];
/// Envelope members a phone may send (never `origin` or `credential`).
const RESOURCE_FIELDS: &[&str] = &["protocol", "type", "id", "operation", "params", "idempotency_key"];

/// Fields a phone may set on commands that start a terminal program. The
/// phone never chooses the program (`argv`, `command`), its directory
/// (`cwd`), its environment (`env`) or a terminal host id.
fn creation_fields(command: &str) -> Option<HashSet<&'static str>> {
    let mutation =
        ["origin", "mutation_id", "expected_generation", "expected_revision", "expected_terminal_revision"];
    let size = ["cols", "rows"];
    let extra: &[&'static str] = match command {
        // The tab's recorded launch on this Mac; the phone names only the tab.
        "restart-tab" => return Some(["surface"].into_iter().collect()),
        // A saved group of this daemon, reopened into one of its panes: the
        // daemon starts each terminal member as the login shell in the
        // folder the record holds; the phone names no program, folder or env.
        "reopen-saved-tab-group" => return Some(["saved", "pane", "transaction"].into_iter().collect()),
        "delete-saved-tab-group" => return Some(["saved"].into_iter().collect()),
        "notification-reply" => return Some(["notification", "text", "reply_id"].into_iter().collect()),
        "new-tab" | "new-pane" => &["pane"],
        "new-pane-right" => &["pane", "width"],
        "split" => &["pane", "dir"],
        "new-screen" => &["workspace"],
        "new-workspace" => &["name"],
        "create-workspace" => return Some(mutation.into_iter().chain(["name", "key"]).collect()),
        "create-terminal" => {
            return Some(mutation.into_iter().chain(size).chain(["workspace", "key", "name"]).collect());
        }
        _ => return None,
    };
    Some(size.into_iter().chain(extra.iter().copied()).collect())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Send the original line.
    Forward,
    /// Send this line instead (no newline): the policy filled in a field the
    /// phone may not choose (the agent tab host).
    Rewrite(Vec<u8>),
    /// Answer the phone with this v12 error line (no newline); never send it on.
    Refuse(String),
}

/// Top-level fields a phone may set on `new-conversation-tab`: a placement,
/// a size and an idempotency key. Never `conversation`/`owner` (another
/// conversation owner) or `page`/`route` (the app's own pages).
const AGENT_TAB_FIELDS: &[&str] =
    &["pane", "workspace", "agent_session", "origin", "mutation_id", "cols", "rows", "transaction"];

/// Fields of `new-conversation-tab`'s `agent_session` a phone may send. The
/// `host` is never the phone's: the policy sets it to this Mac's own agent
/// tab host (the Mac app's `install:<id>`), so the tab runs on this Mac's
/// acpmux and the Mac app shows it as its own chat.
const AGENT_SESSION_FIELDS: &[&str] = &["host", "session", "harness", "host_name"];

/// The per-phone policy.
#[derive(Debug, Clone)]
pub struct DaemonPolicy {
    projection_subject: String,
    /// The link's device id. Every `set-client-info` carries it as
    /// `device_id`, with `remote: true`: a phone is never one of this Mac's
    /// own views and never another device in the sizing order.
    device_id: String,
    /// The `agent_session.host` this Mac's app records on its own agent tabs
    /// (`CMUX_MOBILE_AGENT_TAB_HOST`). Unset: a phone cannot create agent tabs.
    agent_tab_host: Option<String>,
}

impl DaemonPolicy {
    pub fn new(device_id: &str) -> Self {
        Self {
            projection_subject: format!("ios-device:{device_id}"),
            device_id: device_id.to_string(),
            agent_tab_host: None,
        }
    }

    /// The phone's device id this policy was made for.
    pub fn device_id(&self) -> &str {
        self.projection_subject.strip_prefix("ios-device:").unwrap_or(&self.projection_subject)
    }

    /// Lets the phone create agent tabs recorded for `host`.
    pub fn with_agent_tab_host(mut self, host: Option<String>) -> Self {
        self.agent_tab_host = host.filter(|host| !host.is_empty());
        self
    }

    /// Judge one newline-stripped request line.
    pub fn evaluate(&self, line: &[u8]) -> Verdict {
        if line.len() > MAXIMUM_LINE_BYTES {
            return Verdict::Refuse(error_line(None, "too_large", "request exceeds 4 MiB"));
        }
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
            return Verdict::Refuse(error_line(None, "bad_request", "request is not a JSON object"));
        };
        if object.contains_key("protocol") {
            return resource_verdict(object);
        }
        let id = object.get("id");
        let Some(command) = object.get("cmd").and_then(Value::as_str) else {
            return Verdict::Refuse(error_line(id, "bad_request", "missing cmd"));
        };
        if !ALLOWED_COMMANDS.contains(command) {
            return Verdict::Refuse(error_line(
                id,
                "forbidden",
                &format!("{command} is not available to a phone"),
            ));
        }
        if let Some(allowed) = creation_fields(command) {
            let extra: BTreeSet<&str> = object
                .keys()
                .map(String::as_str)
                .filter(|key| !allowed.contains(key) && *key != "id" && *key != "cmd")
                .collect();
            if !extra.is_empty() {
                let names = extra.into_iter().collect::<Vec<_>>().join(", ");
                return Verdict::Refuse(error_line(
                    id,
                    "forbidden",
                    &format!("{command} does not take {names} from a phone"),
                ));
            }
        }
        if (command == "reopen-saved-tab-group" || command == "delete-saved-tab-group")
            && let Some(why) = saved_group_refusal(&object, command == "reopen-saved-tab-group")
        {
            return Verdict::Refuse(error_line(id, "forbidden", &why));
        }
        if command == "notification-reply"
            && let Some(why) = notification_reply_refusal(&object)
        {
            return Verdict::Refuse(error_line(id, "forbidden", &why));
        }
        if command == "set-personal-workspace"
            && let Err(why) = personal_workspace(&object)
        {
            return Verdict::Refuse(error_line(id, "forbidden", &why));
        }
        if (command == "new-browser-tab" || command == "browser-navigate")
            && let Some(url) = object.get("url")
            && !web_url(url)
        {
            return Verdict::Refuse(error_line(
                id,
                "forbidden",
                "a phone may open only http and https pages",
            ));
        }
        if command == "get-frontend-projection" || command == "put-frontend-projection" {
            return self.projection_verdict(&object, id, command == "put-frontend-projection");
        }
        if command == "new-conversation-tab" {
            let id = id.cloned();
            return self.agent_tab_verdict(object, id);
        }
        if command == "set-client-info" {
            return self.client_info_verdict(object);
        }
        if command == "resize-attached-view" && object.contains_key("identity") {
            return sub_view_verdict(object);
        }
        Verdict::Forward
    }

    /// `set-client-info` from a phone, marked as this link's remote device:
    /// `remote: true` and the link's own `device_id`, whatever the phone sent.
    fn client_info_verdict(&self, mut object: Map<String, Value>) -> Verdict {
        object.insert("remote".into(), Value::Bool(true));
        object.insert("device_id".into(), Value::String(self.device_id.clone()));
        match serde_json::to_vec(&Value::Object(object)) {
            Ok(line) => Verdict::Rewrite(line),
            Err(_) => Verdict::Refuse(error_line(None, "bad_request", "request is not a JSON object")),
        }
    }

    /// `new-conversation-tab` from a phone: an acpmux session tab of this
    /// Mac only. The phone names the agent kind (`harness`), optionally a
    /// session it made through its `acpmux` lane, and where the tab goes;
    /// the host is this Mac's own (set here), so no other machine's chat,
    /// conversation owner or page is ever opened by a phone.
    fn agent_tab_verdict(&self, mut object: Map<String, Value>, id: Option<Value>) -> Verdict {
        let refuse = |code: &str, message: &str| Verdict::Refuse(error_line(id.as_ref(), code, message));
        let Some(host) = &self.agent_tab_host else {
            return refuse("unavailable", "this Mac's cmux does not let a phone start agent chats");
        };
        let extra: BTreeSet<&str> = object
            .keys()
            .map(String::as_str)
            .filter(|key| !AGENT_TAB_FIELDS.contains(key) && *key != "id" && *key != "cmd")
            .collect();
        if !extra.is_empty() {
            let names = extra.into_iter().collect::<Vec<_>>().join(", ");
            return refuse("forbidden", &format!("new-conversation-tab does not take {names} from a phone"));
        }
        let Some(Value::Object(session)) = object.get_mut("agent_session") else {
            return refuse("forbidden", "a phone may only open an agent_session tab");
        };
        if let Some(key) = session.keys().find(|key| !AGENT_SESSION_FIELDS.contains(&key.as_str())) {
            return refuse("forbidden", &format!("agent_session does not take {key} from a phone"));
        }
        if session.get("host").is_some_and(|given| given.as_str() != Some(host.as_str())) {
            return refuse("forbidden", "a phone may only open a chat of this Mac");
        }
        let token = |value: Option<&Value>, max: usize| match value {
            None | Some(Value::Null) => true,
            Some(Value::String(text)) => {
                (1..=max).contains(&text.len())
                    && text
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
            }
            Some(_) => false,
        };
        if !token(session.get("harness"), 64) || !token(session.get("session"), 128) {
            return refuse("bad_request", "agent_session harness and session are short identifiers");
        }
        if session.get("host_name").is_some_and(|name| {
            name.as_str().is_none_or(|name| name.len() > 256 || name.chars().any(char::is_control))
        }) {
            return refuse("bad_request", "agent_session host_name is a short name");
        }
        session.insert("host".into(), Value::String(host.clone()));
        match serde_json::to_vec(&Value::Object(object)) {
            Ok(line) => Verdict::Rewrite(line),
            Err(_) => refuse("bad_request", "request is not a JSON object"),
        }
    }

    fn projection_verdict(&self, object: &Map<String, Value>, id: Option<&Value>, write: bool) -> Verdict {
        let scope = object.get("scope").and_then(Value::as_str);
        let subject = object.get("subject_key").and_then(Value::as_str);
        if scope == Some("personal") && subject == Some(self.projection_subject.as_str()) {
            return Verdict::Forward;
        }
        if !write && scope != Some("personal") {
            return Verdict::Forward;
        }
        Verdict::Refuse(error_line(
            id,
            "forbidden",
            &format!("phones may only use the personal projection {}", self.projection_subject),
        ))
    }
}

/// `set-personal-workspace` from a phone: a short session id, a workspace key
/// and a place, nothing else.
/// Why a saved tab group line is refused, or `None`: `saved` is a short
/// identifier (the daemon mints `saved_<hex>`), a reopen names its `pane` (a
/// pane number or a short public id), and `transaction` is 1-128 printable
/// ASCII characters, as the daemon checks.
/// A relay sub-view's `identity` from a phone, without `user_id` and
/// `device_id`: a phone relays no other device, so its sub-views can never
/// take another device's place in the Mac's sizing order.
fn sub_view_verdict(mut object: Map<String, Value>) -> Verdict {
    if let Some(Value::Object(identity)) = object.get_mut("identity") {
        identity.remove("user_id");
        identity.remove("device_id");
    }
    match serde_json::to_vec(&Value::Object(object)) {
        Ok(line) => Verdict::Rewrite(line),
        Err(_) => Verdict::Refuse(error_line(None, "bad_request", "request is not a JSON object")),
    }
}

fn saved_group_refusal(object: &Map<String, Value>, reopen: bool) -> Option<String> {
    if !object.get("saved").and_then(Value::as_str).is_some_and(|saved| short_identifier(saved, 128)) {
        return Some("a saved tab group is named by its id".into());
    }
    if reopen {
        let pane = match object.get("pane") {
            Some(Value::Number(number)) => number.is_u64(),
            Some(Value::String(pane)) => short_identifier(pane, 128),
            _ => false,
        };
        if !pane {
            return Some("reopen-saved-tab-group needs the pane to reopen it in".into());
        }
    }
    if let Some(transaction) = object.get("transaction") {
        let ok = transaction.as_str().is_some_and(|text| {
            (1..=128).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_graphic())
        });
        if !ok {
            return Some("transaction is 1-128 printable characters".into());
        }
    }
    None
}

/// `[A-Za-z0-9._:-]`, 1 to `limit` bytes.
fn short_identifier(text: &str, limit: usize) -> bool {
    (1..=limit).contains(&text.len())
        && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

fn personal_workspace(object: &Map<String, Value>) -> Result<(), String> {
    if let Some(key) = object
        .keys()
        .find(|key| !PERSONAL_WORKSPACE_FIELDS.contains(&key.as_str()) && *key != "id" && *key != "cmd")
    {
        return Err(format!("set-personal-workspace does not take {key} from a phone"));
    }
    let short = |key: &str| {
        object.get(key).and_then(Value::as_str).is_some_and(|text| {
            (1..=128).contains(&text.len())
                && text.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
        })
    };
    if !short("session_id") || !short("workspace_key") {
        return Err("set-personal-workspace needs a session_id and a workspace_key".into());
    }
    if object.get("index").is_some_and(|index| !index.is_u64()) {
        return Err("set-personal-workspace index is a place in the list".into());
    }
    Ok(())
}

/// A `cmux.protocol/2` request from a phone: one of
/// [`ALLOWED_RESOURCE_OPERATIONS`] with only its params, on this Mac's current
/// session. Sent on as the object checked here, serialized again, so a
/// duplicate key cannot mean one thing to this filter and another to the daemon.
fn resource_verdict(object: Map<String, Value>) -> Verdict {
    let id = object.get("id").cloned();
    match check_resource(&object) {
        Ok(()) => match serde_json::to_vec(&Value::Object(object)) {
            Ok(line) => Verdict::Rewrite(line),
            Err(_) => Verdict::Refuse(resource_refusal(id.as_ref(), "request is not a JSON object")),
        },
        Err(why) => Verdict::Refuse(resource_refusal(id.as_ref(), &why)),
    }
}

fn check_resource(object: &Map<String, Value>) -> Result<(), String> {
    if let Some(key) = object.keys().find(|key| !RESOURCE_FIELDS.contains(&key.as_str())) {
        return Err(format!("a phone may not send {key}"));
    }
    if object.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/2")
        || object.get("type").and_then(Value::as_str) != Some("request")
        || !object.get("id").is_some_and(Value::is_string)
    {
        return Err("only cmux.protocol/2 requests".into());
    }
    let operation = object.get("operation").and_then(Value::as_str).unwrap_or_default();
    let Some((_, allowed)) = ALLOWED_RESOURCE_OPERATIONS.iter().find(|(name, _)| *name == operation) else {
        return Err(format!("{operation} is not available to a phone"));
    };
    let Some(Value::Object(params)) = object.get("params") else {
        return Err("params is not an object".into());
    };
    if let Some(key) = params.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(format!("{operation} does not take {key} from a phone"));
    }
    for key in ["machine", "session"] {
        if params.get(key).is_some_and(|value| value.as_str() != Some("current")) {
            return Err(format!("{key} must be current"));
        }
    }
    if operation != "sidebar_layout.get" {
        let key = object.get("idempotency_key").and_then(Value::as_str).unwrap_or_default();
        if !(1..=128).contains(&key.len()) || key.chars().any(char::is_control) {
            return Err(format!("{operation} needs an idempotency_key"));
        }
    }
    if operation.starts_with("workspace_group.") || operation == "workspace.place" {
        group_params(operation, params)?;
    }
    if operation == "sidebar_layout.update" {
        let unpin = params.get("op").and_then(Value::as_object).is_some_and(|op| {
            op.len() == 2
                && op.get("kind").and_then(Value::as_str) == Some("item.remove")
                && op.get("id").and_then(Value::as_str).is_some_and(minted_item)
        });
        if !unpin {
            return Err("a phone may only unpin a workspace from the sidebar".into());
        }
    }
    Ok(())
}

/// A short identifier: 1 to `max` of `[A-Za-z0-9_.:-]` (the daemon's group,
/// room and workspace id characters).
fn short_id(value: Option<&Value>, max: usize) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        (1..=max).contains(&text.len())
            && text.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
    })
}

/// The values of a workspace group operation from a phone: a group name of
/// 1-256 characters without control characters, a palette color, a short
/// group / room id, a live workspace's `ws_` id, a Bool for `collapsed`.
fn group_params(operation: &str, params: &Map<String, Value>) -> Result<(), String> {
    let name = params.get("name");
    if name.is_some_and(|name| {
        name.as_str().is_none_or(|text| {
            text.trim().is_empty() || text.chars().count() > 256 || text.chars().any(char::is_control)
        })
    }) {
        return Err(format!("{operation} name is a short name"));
    }
    if params.get("color").is_some_and(|color| color.as_str().is_none_or(|c| !GROUP_COLORS.contains(&c))) {
        return Err(format!("{operation} color is one of the Mac's group colors"));
    }
    if params.get("collapsed").is_some_and(|collapsed| !collapsed.is_boolean()) {
        return Err(format!("{operation} collapsed is true or false"));
    }
    match operation {
        "workspace_group.create" => {
            if name.is_none() {
                return Err("workspace_group.create needs a name".into());
            }
            if params.get("room").is_some_and(|room| !short_id(Some(room), 64)) {
                return Err("workspace_group.create room is a room id".into());
            }
        }
        "workspace_group.update" | "workspace_group.delete" => {
            if !short_id(params.get("workspace_group"), 64) {
                return Err(format!("{operation} needs a workspace_group"));
            }
            if operation == "workspace_group.update"
                && !["name", "color", "collapsed"].iter().any(|key| params.contains_key(*key))
            {
                return Err("workspace_group.update needs a name, color or collapsed".into());
            }
        }
        _ => {
            let workspace = params.get("workspace").and_then(Value::as_str).unwrap_or_default();
            if !workspace.starts_with("ws_") || !short_id(params.get("workspace"), 128) {
                return Err("workspace.place needs a workspace of this Mac".into());
            }
            match params.get("group") {
                Some(Value::Null) => {}
                Some(group) if short_id(Some(group), 64) => {}
                _ => return Err("workspace.place takes a group, or null to remove it from one".into()),
            }
        }
    }
    Ok(())
}

/// An item id the Mac app minted (`LayoutItemID.mint()`: `itm_` and 16
/// characters of `a-z2-7`), not a built-in item (`itm_home`, `itm_account`).
fn minted_item(id: &str) -> bool {
    id.strip_prefix("itm_").is_some_and(|rest| {
        rest.len() == 16 && rest.bytes().all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b))
    })
}

/// What the daemon must confirm before a line the policy forwarded reaches it:
/// the phone's objects are checked against the Mac's own state, read on a
/// separate connection by the splice (`services::owned_check`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ownership {
    /// `set-personal-workspace`: a live workspace of this session
    /// (`list-workspaces`: `registry_id` and a workspace `key`).
    PersonalWorkspace { session: String, key: String },
    /// Unpin: an item of the pinned section that shows a workspace (`sidebar_layout.get`).
    PinnedWorkspaceTile { item: String },
    /// `workspace_group.update` / `.delete`: a personal group (`list-personal`)
    /// whose workspaces are all of this session (`list-workspaces` `registry_id`).
    OwnGroup { group: String },
    /// `workspace.place`: a live workspace of this session (its `resource_id`), and
    /// the group it joins, when it joins one, as for [`Ownership::OwnGroup`].
    PlaceWorkspace { workspace: String, group: Option<String> },
}

/// The check a forwarded line needs, or None (any other line).
pub fn ownership(line: &[u8]) -> Option<Ownership> {
    let Value::Object(object) = serde_json::from_slice::<Value>(line).ok()? else { return None };
    if object.get("cmd").and_then(Value::as_str) == Some("set-personal-workspace") {
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
        return Some(Ownership::PersonalWorkspace {
            session: text("session_id")?,
            key: text("workspace_key")?,
        });
    }
    let params = object.get("params");
    let text = |key: &str| params?.get(key)?.as_str().map(str::to_string);
    match object.get("operation").and_then(Value::as_str)? {
        "sidebar_layout.update" => {
            let item = params?.get("op")?.get("id")?.as_str()?.to_string();
            Some(Ownership::PinnedWorkspaceTile { item })
        }
        "workspace_group.update" | "workspace_group.delete" => {
            Some(Ownership::OwnGroup { group: text("workspace_group")? })
        }
        "workspace.place" => {
            Some(Ownership::PlaceWorkspace { workspace: text("workspace")?, group: text("group") })
        }
        _ => None,
    }
}

/// The `registry_id` (this session) of a `list-workspaces` reply.
pub fn registry_id(reply: &Value) -> Option<&str> {
    reply.get("data").unwrap_or(reply).get("registry_id").and_then(Value::as_str)
}

/// Whether `list-workspaces` (`reply`) lists a workspace whose `resource_id` is `resource`.
pub fn lists_workspace(reply: &Value, resource: &str) -> bool {
    reply.get("data").unwrap_or(reply).get("workspaces").and_then(Value::as_array).is_some_and(|list| {
        list.iter().any(|ws| ws.get("resource_id").and_then(Value::as_str) == Some(resource))
    })
}

/// Whether `list-personal` (`personal`) has group `group` and every personal
/// row in it is a workspace of session `registry`: the person's own group of
/// this Mac's workspaces (or an empty one), never one holding another
/// machine's workspaces.
pub fn owns_group(personal: &Value, registry: &str, group: &str) -> bool {
    let data = personal.get("data").unwrap_or(personal);
    let known = data.get("groups").and_then(Value::as_array).is_some_and(|groups| {
        groups.iter().any(|candidate| candidate.get("id").and_then(Value::as_str) == Some(group))
    });
    known
        && data.get("workspaces").and_then(Value::as_array).is_none_or(|rows| {
            rows.iter()
                .filter(|row| row.get("group").and_then(Value::as_str) == Some(group))
                .all(|row| row.get("session_id").and_then(Value::as_str) == Some(registry))
        })
}

/// Whether `list-workspaces` (`reply`) lists workspace `key` of session `session`.
pub fn owns_personal_workspace(reply: &Value, session: &str, key: &str) -> bool {
    let data = reply.get("data").unwrap_or(reply);
    data.get("registry_id").and_then(Value::as_str) == Some(session)
        && data
            .get("workspaces")
            .and_then(Value::as_array)
            .is_some_and(|list| list.iter().any(|ws| ws.get("key").and_then(Value::as_str) == Some(key)))
}

/// Whether `sidebar_layout.get` (`reply`, its `result`) has `item` in the pinned
/// section with a workspace ref: a pinned workspace tile, nothing else.
pub fn is_pinned_workspace_tile(reply: &Value, item: &str) -> bool {
    let snapshot = reply.get("result").unwrap_or(reply);
    snapshot.get("sections").and_then(Value::as_array).is_some_and(|sections| {
        sections.iter().filter(|section| section.get("id").and_then(Value::as_str) == Some("sec_pinned")).any(
            |section| {
                section.get("items").and_then(Value::as_array).is_some_and(|items| {
                    items.iter().any(|entry| {
                        entry.get("id").and_then(Value::as_str) == Some(item)
                            && entry.get("ref").and_then(|r| r.get("kind")).and_then(Value::as_str)
                                == Some("workspace")
                    })
                })
            },
        )
    })
}

/// The refusal for a line whose object the Mac does not confirm: a v12 error
/// line for a command, a v2 failure response for a resource request.
pub fn not_owned(line: &[u8], what: &Ownership) -> String {
    let id = serde_json::from_slice::<Value>(line).ok().and_then(|v| v.get("id").cloned());
    match what {
        Ownership::PersonalWorkspace { .. } => {
            error_line(id.as_ref(), "forbidden", "set-personal-workspace takes only a workspace of this Mac")
        }
        Ownership::PinnedWorkspaceTile { .. } => {
            resource_refusal(id.as_ref(), "a phone may only unpin a pinned workspace")
        }
        Ownership::OwnGroup { .. } => {
            resource_refusal(id.as_ref(), "a phone may only change a group of this Mac's workspaces")
        }
        Ownership::PlaceWorkspace { .. } => resource_refusal(
            id.as_ref(),
            "a phone may only move a workspace of this Mac into a group of this Mac's workspaces",
        ),
    }
}

/// A v2 failure response, so the phone's resource client reads it as one.
fn resource_refusal(id: Option<&Value>, why: &str) -> String {
    json!({
        "error": {"code": "origin.forbidden", "details": {"reason": "phone_policy"}, "message": why, "retryable": false},
        "id": id.cloned().unwrap_or(Value::Null),
        "ok": false,
        "protocol": "cmux.protocol/2",
        "type": "response",
    })
    .to_string()
}

/// A web page a phone may open in the Mac's browser: `http(s)://…` or `about:blank`,
/// never `file:`, `javascript:` or an app scheme that would act on the Mac.
fn web_url(url: &Value) -> bool {
    let Some(text) = url.as_str() else { return false };
    let lower = text.trim().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://") || lower == "about:blank"
}

/// The longest text a reply to a terminal notification carries, in bytes.
pub const NOTIFICATION_REPLY_MAX_BYTES: usize = 4096;

/// Why a `notification-reply` is refused: it names one notification (a
/// ledger id) and carries 1 to 4096 bytes of text.
fn notification_reply_refusal(object: &Map<String, Value>) -> Option<String> {
    if object.get("notification").and_then(Value::as_u64).is_none() {
        return Some("notification-reply names a notification id".into());
    }
    if let Some(reply) = object.get("reply_id")
        && !reply.as_str().is_some_and(|r| {
            (8..=64).contains(&r.len()) && r.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return Some("reply_id is the reply's id (8 to 64 letters, digits or dashes)".into());
    }
    match object.get("text").and_then(Value::as_str) {
        Some(text) if !text.is_empty() && text.len() <= NOTIFICATION_REPLY_MAX_BYTES => None,
        _ => Some(format!("notification-reply carries 1 to {NOTIFICATION_REPLY_MAX_BYTES} bytes of text")),
    }
}

/// A v12 error response line, keys sorted like the Swift policy.
pub fn error_line(id: Option<&Value>, code: &str, message: &str) -> String {
    json!({"error": message, "error_code": code, "id": id.cloned().unwrap_or(Value::Null), "ok": false})
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> DaemonPolicy {
        DaemonPolicy::new("phone-1")
    }

    #[test]
    fn allows_listed_commands() {
        assert_eq!(policy().evaluate(br#"{"id":1,"cmd":"identify"}"#), Verdict::Forward);
        assert_eq!(
            policy().evaluate(br#"{"id":2,"cmd":"send","surface":3,"text":"ls\n"}"#),
            Verdict::Forward
        );
        assert_eq!(
            policy().evaluate(br#"{"id":3,"cmd":"new-tab","pane":1,"cols":80,"rows":24}"#),
            Verdict::Forward
        );
    }

    /// The exact lines the iOS app's terminal tabs send (CmuxMobileLive DaemonTerminalSession
    /// through CmuxMobileTransport DaemonClient: flat params, sorted keys, string ids).
    #[test]
    fn allows_the_phone_terminal_session() {
        for line in [
            br#"{"cmd":"identify","id":"m1"}"#.as_slice(),
            br#"{"cmd":"attach-surface","id":"m2","surface":7}"#,
            br#"{"bytes":"bHMK","cmd":"send","id":"m3","surface":7}"#,
            br#"{"cmd":"resize-surface","cols":80,"id":"m4","rows":24,"surface":7}"#,
            br#"{"cmd":"release-surface-size","id":"m5","surface":7}"#,
            br#"{"cmd":"detach-attached-view","id":"m6","surface":7}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        // Starting or replacing the program behind a terminal stays the Mac's.
        for line in [
            br#"{"cmd":"respawn-surface","id":"m7","surface":7,"argv":["sh"]}"#.as_slice(),
            br#"{"cmd":"run","id":"m8","argv":["sh","-c","id"]}"#,
            br#"{"cmd":"create-terminal","id":"m9","workspace":1,"argv":["sh"]}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn browser_tabs_open_web_pages_only() {
        assert_eq!(
            policy().evaluate(br#"{"cmd":"new-browser-tab","id":1,"pane":2,"url":"https://example.com"}"#),
            Verdict::Forward
        );
        assert_eq!(
            policy()
                .evaluate(br#"{"cmd":"browser-navigate","id":2,"surface":3,"url":"http://localhost:3000"}"#),
            Verdict::Forward
        );
        for line in [
            br#"{"cmd":"new-browser-tab","id":3,"pane":2,"url":"file:///etc/passwd"}"#.as_slice(),
            br#"{"cmd":"browser-navigate","id":4,"surface":3,"url":"javascript:alert(1)"}"#,
            br#"{"cmd":"browser-navigate","id":5,"surface":3,"url":"cmux://open"}"#,
            br#"{"cmd":"new-browser-tab","id":6,"pane":2,"url":7}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    /// The phone is a remote client, never the app: it cannot prove the install key
    /// (`client-hello`), so the daemon gives its lane origin `agent` and Gate A2
    /// (`user`-only operations) refuses it there too.
    #[test]
    fn the_phone_cannot_claim_the_app_identity() {
        for line in [
            br#"{"cmd":"client-hello","id":"h1","role":"main","install_id":"x"}"#.as_slice(),
            br#"{"cmd":"client-hello","id":"h2","role":"page_relay","page":"settings"}"#,
            br#"{"cmd":"origin.confirmation.issue","id":"h3"}"#,
            br#"{"cmd":"apps.install","id":"h4"}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn refuses_unlisted_and_command_bearing_requests() {
        for line in [
            br#"{"id":1,"cmd":"run","argv":["sh"]}"#.as_slice(),
            br#"{"id":1,"cmd":"create-surface-with-receipt"}"#,
            br#"{"id":1,"cmd":"new-tab","argv":["/bin/sh","-c","id"]}"#,
            br#"{"id":1,"cmd":"create-terminal","command":"id"}"#,
            br#"{"id":1,"cmd":"split","cwd":"/"}"#,
            br#"{"id":1,"cmd":"new-workspace","env":{"BASH_ENV":"/tmp/x"}}"#,
            br#"{"id":1,"cmd":"register-browser-provider"}"#,
        ] {
            let Verdict::Refuse(answer) = policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            let answer: Value = serde_json::from_str(&answer).unwrap();
            assert_eq!(answer["ok"], false);
            assert_eq!(answer["error_code"], "forbidden");
            assert_eq!(answer["id"], 1);
        }
    }

    /// Restart Shell: the dead tab's own shell again, on this Mac; the phone
    /// names the tab and nothing else (no program, folder, env or alias).
    #[test]
    fn restart_shell_takes_only_the_tab() {
        assert_eq!(policy().evaluate(br#"{"id":1,"cmd":"restart-tab","surface":12}"#), Verdict::Forward);
        assert_eq!(
            policy().evaluate(br#"{"id":1,"cmd":"restart-tab","surface":"tab_01J"}"#),
            Verdict::Forward
        );
        for line in [
            br#"{"id":1,"cmd":"restart-tab","surface":12,"command":"id"}"#.as_slice(),
            br#"{"id":1,"cmd":"restart-tab","surface":12,"argv":["sh"]}"#,
            br#"{"id":1,"cmd":"restart-tab","surface":12,"cwd":"/"}"#,
            br#"{"id":1,"cmd":"restart-tab","surface":12,"env":{"BASH_ENV":"/tmp/x"}}"#,
            br#"{"id":1,"cmd":"restart-tab","tab":12}"#,
            br#"{"id":1,"cmd":"restart-tab","surface":12,"initial_command":"id"}"#,
        ] {
            let Verdict::Refuse(answer) = policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            assert!(answer.contains("forbidden"), "{answer}");
        }
    }

    /// Reopen / Delete Saved Tab Group: the saved id and a pane only; the
    /// daemon starts each terminal of the record as the login shell in its
    /// saved folder, so no program, folder, env or host comes from the phone.
    #[test]
    fn saved_tab_groups_take_only_the_saved_id_and_a_pane() {
        for line in [
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"saved_0123abcd","pane":4}"#.as_slice(),
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"saved_0123abcd","pane":"pane_01J","transaction":"tx-1"}"#,
            br#"{"id":1,"cmd":"delete-saved-tab-group","saved":"saved_0123abcd"}"#,
            br#"{"id":1,"cmd":"list-saved-tab-groups"}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        for line in [
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"command":"id"}"#.as_slice(),
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"argv":["sh"]}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"cwd":"/"}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"env":{"BASH_ENV":"/tmp/x"}}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"terminal_host":"h"}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"members":[]}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"origin":"user"}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s"}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":-1}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":"a b"}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"transaction":""}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":"../x","pane":4}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","saved":12,"pane":4}"#,
            br#"{"id":1,"cmd":"reopen-saved-tab-group","pane":4}"#,
            br#"{"id":1,"cmd":"delete-saved-tab-group","saved":"s","cwd":"/"}"#,
            br#"{"id":1,"cmd":"delete-saved-tab-group"}"#,
        ] {
            let Verdict::Refuse(answer) = policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            assert!(answer.contains("forbidden"), "{answer}");
        }
    }

    #[test]
    fn bad_json_and_missing_cmd() {
        let Verdict::Refuse(answer) = policy().evaluate(b"not json") else { panic!() };
        assert!(answer.contains("bad_request") && answer.contains("\"id\":null"));
        let Verdict::Refuse(answer) = policy().evaluate(br#"{"id":"a"}"#) else { panic!() };
        assert!(answer.contains("missing cmd") && answer.contains("\"id\":\"a\""));
    }

    #[test]
    fn projections_are_scoped_to_the_phone() {
        let own = br#"{"id":1,"cmd":"put-frontend-projection","scope":"personal","subject_key":"ios-device:phone-1"}"#;
        assert_eq!(policy().evaluate(own), Verdict::Forward);
        let shared_read = br#"{"id":1,"cmd":"get-frontend-projection","scope":"shared"}"#;
        assert_eq!(policy().evaluate(shared_read), Verdict::Forward);
        let shared_write = br#"{"id":1,"cmd":"put-frontend-projection","scope":"shared"}"#;
        assert!(matches!(policy().evaluate(shared_write), Verdict::Refuse(_)));
        let other =
            br#"{"id":1,"cmd":"get-frontend-projection","scope":"personal","subject_key":"ios-device:x"}"#;
        assert!(matches!(policy().evaluate(other), Verdict::Refuse(_)));
    }

    fn agent_policy() -> DaemonPolicy {
        policy().with_agent_tab_host(Some("install:mac-1".into()))
    }

    #[test]
    fn agent_tabs_get_this_macs_host() {
        let line = br#"{"id":1,"cmd":"new-conversation-tab","pane":4,"mutation_id":"k","origin":"ios","agent_session":{"harness":"claude","session":"0199-abc","host_name":"Phone"}}"#;
        let Verdict::Rewrite(rewritten) = agent_policy().evaluate(line) else { panic!("not rewritten") };
        let value: Value = serde_json::from_slice(&rewritten).unwrap();
        assert_eq!(value["agent_session"]["host"], "install:mac-1");
        assert_eq!(value["agent_session"]["harness"], "claude");
        assert_eq!(value["pane"], 4);
        assert_eq!(value["id"], 1);
        // The phone may name this Mac's host itself, never another.
        let own = br#"{"id":1,"cmd":"new-conversation-tab","workspace":2,"agent_session":{"host":"install:mac-1"}}"#;
        assert!(matches!(agent_policy().evaluate(own), Verdict::Rewrite(_)));
    }

    #[test]
    fn agent_tabs_refuse_other_sources_and_hosts() {
        for (line, code) in [
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"host":"registry:x"}}"#.as_slice(), "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"conversation":"c","owner":"local"}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"page":"settings"}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"claude","command":"sh"}}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"a b"}}"#, "bad_request"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"session":7}}"#, "bad_request"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"host_name":"a\nb"}}"#, "bad_request"),
        ] {
            let Verdict::Refuse(answer) = agent_policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            let answer: Value = serde_json::from_str(&answer).unwrap();
            assert_eq!(answer["error_code"], code, "{}", String::from_utf8_lossy(line));
            assert_eq!(answer["id"], 1);
        }
        // Without a configured host (an older Mac app), no agent tabs at all.
        let line = br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"claude"}}"#;
        let Verdict::Refuse(answer) = policy().evaluate(line) else { panic!() };
        assert!(answer.contains("unavailable"));
    }

    /// The shape of the lines a Feed reply to a terminal agent sends
    /// (CmuxMobileLive TerminalFeed.reply): the daemon's capabilities, the
    /// foreground program, then one `send` that pastes and submits only while
    /// that program (its full path, as `process-info` names it) is still in
    /// the foreground and its agent waits at its prompt in that session. All
    /// were already on the allowlist (the phone's terminal keyboard sends
    /// `send`); the reply opens nothing new, and `notification-reply` stays
    /// refused.
    #[test]
    fn allows_the_terminal_feed_reply() {
        for line in [
            br#"{"cmd":"identify","id":"m0"}"#.as_slice(),
            br#"{"cmd":"process-info","id":"m1","surface":7}"#,
            br#"{"cmd":"send","expect_agent":{"session":"0b6c3f8e"},"expect_foreground":"/Users/me/.local/share/claude/versions/2.1.300","id":"m2","paste":true,"submit":true,"surface":7,"text":"run the tests"}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        // A notification's own reply is PR B's narrow command, with only its notification
        // and text (`notification_reply_takes_only_its_notification_and_text`); a stray
        // field still refuses it.
        let line = br#"{"cmd":"notification-reply","id":"m4","notification":1,"text":"y","surface":7}"#.as_slice();
        assert!(matches!(policy().evaluate(line), Verdict::Refuse(_)));
    }

    /// The exact lines the iOS Feed sends for terminal agents (CmuxMobileLive
    /// TerminalFeed): the notification ledger read and the per-tab read mark
    /// the Mac's own notifications panel uses. Both were already on the
    /// allowlist; nothing new is opened for the Feed.
    #[test]
    fn allows_the_terminal_feed() {
        for line in [
            br#"{"cmd":"subscribe","id":"m1","tree_events":"deltas"}"#.as_slice(),
            br#"{"cmd":"list-notifications","id":"m2","limit":100}"#,
            br#"{"cmd":"ack-tab-notifications","id":"m3","surface":7}"#,
            br#"{"cmd":"list-agents","id":"m4"}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        // Nothing beyond the ledger: the activity stream and the session
        // journal stay refused (a reply to a terminal notification is its own
        // narrow command, `notification_reply_takes_only_its_notification_and_text`).
        for line in [
            br#"{"cmd":"subscribe-activity","id":"m6"}"#.as_slice(),
            br#"{"cmd":"session.journal.subscribe","id":"m7"}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    /// A reply to a terminal notification (PROTOCOL.md "Terminal replies"):
    /// the notification's id and the person's text, nothing else. hostd
    /// answers it itself (`mailbox_apply::reply_to_notification`): the text
    /// goes only to the terminal that posted that notification.
    #[test]
    fn notification_reply_takes_only_its_notification_and_text() {
        assert_eq!(
            policy().evaluate(br#"{"cmd":"notification-reply","id":"m5","notification":1,"text":"y"}"#),
            Verdict::Forward
        );
        let long = format!(
            r#"{{"cmd":"notification-reply","id":"m6","notification":1,"text":"{}"}}"#,
            "x".repeat(4097)
        );
        let exact = format!(
            r#"{{"cmd":"notification-reply","id":"m6","notification":1,"text":"{}"}}"#,
            "x".repeat(4096)
        );
        assert_eq!(policy().evaluate(exact.as_bytes()), Verdict::Forward);
        // The reply's id, so a copy that also went through the mailbox is applied once.
        assert_eq!(
            policy().evaluate(
                br#"{"cmd":"notification-reply","id":"m8","notification":1,"text":"y","reply_id":"0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807"}"#
            ),
            Verdict::Forward
        );
        assert!(matches!(
            policy().evaluate(
                br#"{"cmd":"notification-reply","id":"m8","notification":1,"text":"y","reply_id":"a b"}"#
            ),
            Verdict::Refuse(_)
        ));
        for line in [
            // Another field: a surface, a command, raw bytes, a paste flag.
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"text":"y","surface":3}"#.as_slice(),
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"text":"y","command":"ls"}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"bytes":"bHMK"}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"text":"y","paste":false}"#,
            // Missing or ill-typed fields; empty text.
            br#"{"cmd":"notification-reply","id":"m7","text":"y"}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":"1","text":"y"}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":-1,"text":"y"}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":1}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"text":7}"#,
            br#"{"cmd":"notification-reply","id":"m7","notification":1,"text":""}"#,
            long.as_bytes(),
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(&line[..line.len().min(120)])
            );
        }
    }

    fn resource(operation: &str, params: Value, key: Option<&str>) -> Vec<u8> {
        let mut object = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "r7", "operation": operation, "params": params});
        if let Some(key) = key {
            object["idempotency_key"] = key.into();
        }
        serde_json::to_vec(&object).unwrap()
    }

    fn refused(line: &[u8]) -> Value {
        let Verdict::Refuse(answer) = policy().evaluate(line) else {
            panic!("forwarded {}", String::from_utf8_lossy(line));
        };
        serde_json::from_str(&answer).unwrap()
    }

    /// Clear All Notifications, the person's pins and Unpin Workspace: the exact
    /// lines the iOS app sends (CmuxMobileLive), on this Mac's current session.
    #[test]
    fn allows_the_workspace_resource_ops() {
        let current = json!({"machine": "current", "session": "current"});
        for line in [
            resource("notification.clear", current.clone(), Some("cmux-next-ios-notification-clear-1")),
            resource("sidebar_layout.get", current, None),
            resource(
                "sidebar_layout.update",
                json!({"machine": "current", "session": "current", "op": {"kind": "item.remove", "id": "itm_abcdefgh234567ab"}}),
                Some("cmux-next-ios-unpin-1"),
            ),
        ] {
            let Verdict::Rewrite(sent) = policy().evaluate(&line) else {
                panic!("not forwarded {}", String::from_utf8_lossy(&line));
            };
            assert_eq!(
                serde_json::from_slice::<Value>(&sent).unwrap(),
                serde_json::from_slice::<Value>(&line).unwrap()
            );
        }
    }

    #[test]
    fn refuses_other_resource_ops_and_params() {
        let current = json!({"machine": "current", "session": "current"});
        for line in [
            // Any other operation, read or write.
            resource("notification.list", current.clone(), None),
            resource("notification.create", current.clone(), Some("k")),
            resource("pane.run", current.clone(), Some("k")),
            resource("workspace.agent_folder.set", current.clone(), Some("k")),
            // Another machine or session, or a narrower clear the Mac never sends from a phone.
            resource("notification.clear", json!({"machine": "other", "session": "current"}), Some("k")),
            resource("notification.clear", json!({"machine": "current", "session": "s2"}), Some("k")),
            resource(
                "notification.clear",
                json!({"machine": "current", "session": "current", "terminal_id": "term_1"}),
                Some("k"),
            ),
            // A mutation without its idempotency key.
            resource("notification.clear", current.clone(), None),
            // Layout edits other than unpinning a minted item.
            resource("sidebar_layout.update", json!({"op": {"kind": "layout.reset"}}), Some("k")),
            resource(
                "sidebar_layout.update",
                json!({"op": {"kind": "item.remove", "id": "itm_account"}}),
                Some("k"),
            ),
            resource(
                "sidebar_layout.update",
                json!({"op": {"kind": "item.remove", "id": "itm_ABCDEFGH234567AB"}}),
                Some("k"),
            ),
            resource(
                "sidebar_layout.update",
                json!({"op": {"kind": "item.remove", "id": "itm_abcdefgh234567ab", "x": 1}}),
                Some("k"),
            ),
            resource(
                "sidebar_layout.update",
                json!({"op": {"kind": "section.remove", "id": "sec_pinned"}}),
                Some("k"),
            ),
            resource(
                "sidebar_layout.update",
                json!({"op": {"kind": "item.add", "section": "sec_pinned", "index": 0,
                "item": {"id": "itm_abcdefgh234567ab", "ref": {"kind": "app", "value": "x"}}}}),
                Some("k"),
            ),
        ] {
            let answer = refused(&line);
            assert_eq!(answer["ok"], false, "{}", String::from_utf8_lossy(&line));
            assert_eq!(answer["type"], "response");
            assert_eq!(answer["id"], "r7");
        }
        // Envelope members a phone never sends: an origin claim or a credential.
        for extra in [json!({"origin": {"claim": "user"}}), json!({"credential": "x"})] {
            let mut object: Value =
                serde_json::from_slice(&resource("notification.clear", current.clone(), Some("k"))).unwrap();
            object.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            refused(&serde_json::to_vec(&object).unwrap());
        }
        refused(br#"{"protocol":"cmux.protocol/1","type":"request","id":"r1","operation":"notification.clear","params":{},"idempotency_key":"k"}"#);
    }

    /// The Mac's own state confirms the phone's objects: a live workspace of this
    /// session for the sidebar order, a pinned workspace tile for Unpin.
    #[test]
    fn ownership_is_checked_against_the_macs_state() {
        let personal = br#"{"cmd":"set-personal-workspace","id":"m1","session_id":"reg","workspace_key":"k1","index":2}"#;
        let what = ownership(personal).unwrap();
        assert_eq!(what, Ownership::PersonalWorkspace { session: "reg".into(), key: "k1".into() });
        let tree =
            json!({"ok": true, "data": {"registry_id": "reg", "workspaces": [{"key": "k1"}, {"key": "k2"}]}});
        assert!(owns_personal_workspace(&tree, "reg", "k1"));
        assert!(!owns_personal_workspace(&tree, "reg", "k9"), "a key the Mac does not list");
        assert!(!owns_personal_workspace(&tree, "other", "k1"), "another session's row");
        assert!(not_owned(personal, &what).contains("forbidden"));

        let unpin = resource(
            "sidebar_layout.update",
            json!({"op": {"kind": "item.remove", "id": "itm_abcdefgh234567ab"}}),
            Some("k"),
        );
        let what = ownership(&unpin).unwrap();
        assert_eq!(what, Ownership::PinnedWorkspaceTile { item: "itm_abcdefgh234567ab".into() });
        let layout = |section: &str, kind: &str| {
            json!({"ok": true, "result": {"sections": [
                {"id": "sec_top", "items": [{"id": "itm_home", "ref": {"kind": "app", "value": "cmux/home"}}]},
                {"id": section, "items": [{"id": "itm_abcdefgh234567ab", "ref": {"kind": kind, "value": "reg:ws_1"}}]},
            ]}})
        };
        assert!(is_pinned_workspace_tile(&layout("sec_pinned", "workspace"), "itm_abcdefgh234567ab"));
        assert!(
            !is_pinned_workspace_tile(&layout("sec_custom", "workspace"), "itm_abcdefgh234567ab"),
            "another section"
        );
        assert!(
            !is_pinned_workspace_tile(&layout("sec_pinned", "link"), "itm_abcdefgh234567ab"),
            "a link tile"
        );
        assert!(
            !is_pinned_workspace_tile(&layout("sec_pinned", "workspace"), "itm_zzzzzzzzzzzzzzzz"),
            "an unknown item"
        );
        assert_eq!(serde_json::from_str::<Value>(&not_owned(&unpin, &what)).unwrap()["type"], "response");
        assert_eq!(ownership(br#"{"cmd":"list-personal","id":1}"#), None);
    }

    /// Workspace groups: the exact lines the iOS app sends (CmuxMobileLive
    /// `LiveWorkspaceGroups`), as the Mac's own sidebar sends them.
    #[test]
    fn allows_the_workspace_group_ops() {
        let with = |extra: Value| {
            let mut params = json!({"machine": "current", "session": "current"});
            params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            params
        };
        for (operation, params) in [
            ("workspace_group.create", with(json!({"name": "Release", "color": "red", "room": "default"}))),
            ("workspace_group.create", with(json!({"name": "New Group"}))),
            ("workspace_group.update", with(json!({"workspace_group": "grp_0a1b", "name": "Ship"}))),
            ("workspace_group.update", with(json!({"workspace_group": "grp_0a1b", "color": "cyan"}))),
            ("workspace_group.update", with(json!({"workspace_group": "grp_0a1b", "collapsed": true}))),
            ("workspace_group.delete", with(json!({"workspace_group": "grp_0a1b"}))),
            ("workspace.place", with(json!({"workspace": "ws_01HZY", "group": "grp_0a1b"}))),
            ("workspace.place", with(json!({"workspace": "ws_01HZY", "group": null}))),
        ] {
            let line = resource(operation, params, Some("cmux-next-ios-group-1"));
            let Verdict::Rewrite(sent) = policy().evaluate(&line) else {
                panic!("not forwarded {}", String::from_utf8_lossy(&line));
            };
            assert_eq!(
                serde_json::from_slice::<Value>(&sent).unwrap(),
                serde_json::from_slice::<Value>(&line).unwrap()
            );
        }
    }

    #[test]
    fn refuses_other_workspace_group_shapes() {
        let current = json!({"machine": "current", "session": "current"});
        let with = |extra: Value| {
            let mut params = current.clone();
            params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            params
        };
        for (operation, params) in [
            // Operations the phone does not need: list, move, rooms.
            ("workspace_group.list", current.clone()),
            ("workspace_group.move", with(json!({"workspace_group": "g", "index": 0}))),
            ("workspace.placement.list", current.clone()),
            ("room.create", with(json!({"name": "x"}))),
            ("room.pin", with(json!({"workspace": "ws_1", "room": "default"}))),
            // Fields the phone never sets.
            ("workspace_group.create", with(json!({"name": "a", "index": 0}))),
            ("workspace_group.create", with(json!({"name": "a", "collapsed": true}))),
            ("workspace_group.create", with(json!({"name": "a", "workspace_group": "grp_x"}))),
            ("workspace_group.create", with(json!({"name": "a", "icon": "star"}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "room": "other"}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "top_index": 0}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "pinned": true}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "icon": "star"}))),
            ("workspace.place", with(json!({"workspace": "ws_1", "group": "g", "index": 2}))),
            ("workspace.place", with(json!({"workspace": "ws_1", "group": "g", "cwd": "/"}))),
            ("workspace_group.create", with(json!({"name": "a", "command": "id"}))),
            ("workspace_group.create", with(json!({"name": "a", "argv": ["sh"]}))),
            ("workspace_group.create", with(json!({"name": "a", "env": {"BASH_ENV": "/tmp/x"}}))),
            // Bad values.
            ("workspace_group.create", current.clone()),
            ("workspace_group.create", with(json!({"name": "  "}))),
            ("workspace_group.create", with(json!({"name": "a\nb"}))),
            ("workspace_group.create", with(json!({"name": "x".repeat(257)}))),
            ("workspace_group.create", with(json!({"name": 7}))),
            ("workspace_group.create", with(json!({"name": "a", "color": "#ff0000"}))),
            ("workspace_group.create", with(json!({"name": "a", "color": "chartreuse"}))),
            ("workspace_group.create", with(json!({"name": "a", "room": "a room"}))),
            ("workspace_group.update", with(json!({"name": "a"}))),
            ("workspace_group.update", with(json!({"workspace_group": "g"}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "collapsed": "yes"}))),
            ("workspace_group.update", with(json!({"workspace_group": "g", "color": null}))),
            ("workspace_group.delete", current.clone()),
            ("workspace_group.delete", with(json!({"workspace_group": "../g"}))),
            ("workspace.place", with(json!({"workspace": "ws_1"}))),
            ("workspace.place", with(json!({"group": "g"}))),
            ("workspace.place", with(json!({"workspace": "current", "group": "g"}))),
            ("workspace.place", with(json!({"workspace": 3, "group": "g"}))),
            ("workspace.place", with(json!({"workspace": "ws_1", "group": 3}))),
            // Another machine or session.
            ("workspace_group.delete", json!({"machine": "other", "workspace_group": "g"})),
            ("workspace.place", json!({"session": "s2", "workspace": "ws_1", "group": null})),
        ] {
            let line = resource(operation, params, Some("k"));
            let answer = refused(&line);
            assert_eq!(answer["ok"], false, "{}", String::from_utf8_lossy(&line));
            assert_eq!(answer["type"], "response");
        }
        // A mutation without its idempotency key.
        refused(&resource("workspace_group.delete", with(json!({"workspace_group": "g"})), None));
    }

    /// A group the phone changes, or a workspace it places, is confirmed by the
    /// Mac's own state: a group of this session's workspaces, a live workspace.
    #[test]
    fn group_ownership_is_checked_against_the_macs_state() {
        let update =
            resource("workspace_group.update", json!({"workspace_group": "grp_1", "name": "x"}), Some("k"));
        assert_eq!(ownership(&update), Some(Ownership::OwnGroup { group: "grp_1".into() }));
        let delete = resource("workspace_group.delete", json!({"workspace_group": "grp_1"}), Some("k"));
        assert_eq!(ownership(&delete), Some(Ownership::OwnGroup { group: "grp_1".into() }));
        let place = resource("workspace.place", json!({"workspace": "ws_a", "group": "grp_1"}), Some("k"));
        assert_eq!(
            ownership(&place),
            Some(Ownership::PlaceWorkspace { workspace: "ws_a".into(), group: Some("grp_1".into()) })
        );
        let out = resource("workspace.place", json!({"workspace": "ws_a", "group": null}), Some("k"));
        assert_eq!(
            ownership(&out),
            Some(Ownership::PlaceWorkspace { workspace: "ws_a".into(), group: None })
        );
        // Creating a group names no existing object.
        assert_eq!(ownership(&resource("workspace_group.create", json!({"name": "a"}), Some("k"))), None);

        let tree = json!({"ok": true, "data": {"registry_id": "reg", "workspaces": [
            {"key": "k1", "resource_id": "ws_a"}, {"key": "k2", "resource_id": "ws_b"}]}});
        assert_eq!(registry_id(&tree), Some("reg"));
        assert!(lists_workspace(&tree, "ws_a"));
        assert!(!lists_workspace(&tree, "ws_z"), "a workspace the Mac does not list");
        let personal = json!({"ok": true, "data": {
        "groups": [{"id": "grp_1"}, {"id": "grp_empty"}, {"id": "grp_mixed"}, {"id": "grp_other"}],
        "workspaces": [
            {"session_id": "reg", "workspace_key": "k1", "group": "grp_1"},
            {"session_id": "reg", "workspace_key": "k2", "group": "grp_mixed"},
            {"session_id": "remote", "workspace_key": "r1", "group": "grp_mixed"},
            {"session_id": "remote", "workspace_key": "r2", "group": "grp_other"},
            {"session_id": "reg", "workspace_key": "k3"},
        ]}});
        assert!(owns_group(&personal, "reg", "grp_1"));
        assert!(owns_group(&personal, "reg", "grp_empty"), "an empty group of the person's");
        assert!(!owns_group(&personal, "reg", "grp_mixed"), "holds another machine's workspace");
        assert!(!owns_group(&personal, "reg", "grp_other"), "another machine's group");
        assert!(!owns_group(&personal, "reg", "grp_unknown"), "no such group");
        for (line, what) in [
            (&update, Ownership::OwnGroup { group: "grp_1".into() }),
            (&place, Ownership::PlaceWorkspace { workspace: "ws_a".into(), group: None }),
        ] {
            let answer: Value = serde_json::from_str(&not_owned(line, &what)).unwrap();
            assert_eq!(answer["type"], "response");
            assert_eq!(answer["error"]["code"], "origin.forbidden");
        }
    }

    /// A duplicate key reaches the daemon as one value: the object checked here.
    #[test]
    fn duplicate_keys_are_sent_as_checked() {
        let line = br#"{"protocol":"cmux.protocol/2","type":"request","id":"r1","operation":"sidebar_layout.get","operation":"pane.run","params":{"machine":"current","session":"current"}}"#;
        // serde keeps the last duplicate, so the policy judges `pane.run` and refuses it.
        assert!(matches!(policy().evaluate(line), Verdict::Refuse(_)));
        let line = br#"{"protocol":"cmux.protocol/2","type":"request","id":"r1","operation":"pane.run","operation":"sidebar_layout.get","params":{"machine":"current","session":"current"}}"#;
        let Verdict::Rewrite(sent) = policy().evaluate(line) else { panic!("not rewritten") };
        let text = String::from_utf8(sent).unwrap();
        assert_eq!(text.matches("\"operation\"").count(), 1, "{text}");
        assert!(text.contains("sidebar_layout.get") && !text.contains("pane.run"), "{text}");
    }

    /// Move Workspace Up / Down in the person's own sidebar order.
    #[test]
    fn personal_order_is_a_place_only() {
        for line in [
            br#"{"cmd":"list-personal","id":"m1"}"#.as_slice(),
            br#"{"cmd":"set-personal-workspace","id":"m2","session_id":"reg_01abc","workspace_key":"0b8f6c2e-1d2a-4f00-9a7b-1c2d3e4f5a6b","index":3}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        for line in [
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"s","workspace_key":"k","index":1,"remote_localhost":true}"#.as_slice(),
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"s","workspace_key":"k","group":"g"}"#,
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"s","workspace_key":"k","theme":"x"}"#,
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"s","workspace_key":"k","browser_profile_id":"p"}"#,
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"s","workspace_key":"k","index":-1}"#,
            br#"{"cmd":"set-personal-workspace","id":1,"workspace_key":"k","index":1}"#,
            br#"{"cmd":"set-personal-workspace","id":1,"session_id":"a b","workspace_key":"k"}"#,
            br#"{"cmd":"set-personal-terminal","id":1,"session_id":"s","terminal_key":"t","theme":"x"}"#,
        ] {
            let Verdict::Refuse(answer) = policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            assert!(answer.contains("forbidden"), "{answer}");
        }
    }

    /// `host-size-policy-v1`: the sizing commands pass; `set-client-info`
    /// always names this link's device and marks it remote, so a phone can
    /// neither pose as this Mac nor as another phone in the sizing order.
    #[test]
    fn phone_sizing_commands_pass_and_client_info_is_marked_remote() {
        for line in [
            br#"{"cmd":"get-size-state","id":"s1","surface":7}"#.as_slice(),
            br#"{"cmd":"note-size-activity","id":"s2","surface":7}"#,
            br#"{"cmd":"get-host-size-policy","id":"s3","surface":7}"#,
            br#"{"cmd":"set-host-size-policy","id":"s4","policy":{"mode":"priority","order":["mac"]}}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        for line in [
            br#"{"cmd":"set-size-policy","id":"s5","surface":7,"policy":{"mode":"fixed"}}"#.as_slice(),
            br#"{"cmd":"set-size-counts","id":"s6","surface":7,"counts":false}"#,
        ] {
            assert!(matches!(policy().evaluate(line), Verdict::Refuse(_)), "{}", String::from_utf8_lossy(line));
        }
        let line = br#"{"cmd":"set-client-info","id":"c1","device_kind":"mac","device_id":"someone-else","remote":false}"#;
        let Verdict::Rewrite(sent) = policy().evaluate(line) else { panic!("not rewritten") };
        let sent: Value = serde_json::from_slice(&sent).unwrap();
        assert_eq!(sent["remote"], true);
        assert_eq!(sent["device_id"], "phone-1");
        assert_eq!(sent["device_kind"], "mac");
        assert_eq!(sent["id"], "c1");
    }

    /// A relay sub-view's identity from a phone never names a user or a
    /// device (review 2 finding 1): the daemon gives it its own key.
    #[test]
    fn phone_sub_view_identity_names_no_user_or_device() {
        let line = br#"{"cmd":"resize-attached-view","id":"r1","surface":7,"view":"v","cols":40,"rows":20,"identity":{"user_id":"u","device_id":"ipad-1","device_kind":"ipad","device_name":"iPad"}}"#;
        let Verdict::Rewrite(sent) = policy().evaluate(line) else { panic!("not rewritten") };
        let sent: Value = serde_json::from_slice(&sent).unwrap();
        assert_eq!(sent["identity"], serde_json::json!({"device_kind":"ipad","device_name":"iPad"}));
        assert_eq!(sent["cols"], 40);
        let bare = br#"{"cmd":"resize-attached-view","id":"r2","surface":7,"view":"v","cols":40,"rows":20}"#;
        assert_eq!(policy().evaluate(bare), Verdict::Forward);
    }

    #[test]
    fn mirrors_the_swift_allowlist() {
        let swift = include_str!(
            "../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift"
        );
        let start = swift.find("allowedCommands: Set<String> = [").expect("allowlist in Swift");
        let end = start + swift[start..].find("]\n").expect("end of allowlist");
        let swift_commands: HashSet<&str> = swift[start..end].split('"').skip(1).step_by(2).collect();
        // `notification-reply` is answered by hostd itself, never by the daemon, so
        // the Mac's own phone lane (an allowlist of daemon commands) leaves it out.
        let rust_commands: HashSet<&str> =
            ALLOWED_COMMANDS.iter().copied().filter(|command| *command != "notification-reply").collect();
        assert_eq!(swift_commands, rust_commands);
        let start = swift
            .find("allowedResourceOperations: [String: Set<String>] = [")
            .expect("resource ops in Swift");
        let end = start + swift[start..].find("]\n").expect("end of resource ops");
        let swift_ops: Vec<&str> = swift[start..end].split('"').skip(1).step_by(2).collect();
        let rust_ops: Vec<&str> = ALLOWED_RESOURCE_OPERATIONS
            .iter()
            .flat_map(|(name, params)| std::iter::once(*name).chain(params.iter().copied()))
            .collect();
        assert_eq!(swift_ops, rust_ops);
        let start = swift.find("personalWorkspaceFields: [String] = [").expect("personal fields in Swift");
        let end = start + swift[start..].find("]\n").expect("end of personal fields");
        let swift_fields: Vec<&str> = swift[start..end].split('"').skip(1).step_by(2).collect();
        assert_eq!(swift_fields, PERSONAL_WORKSPACE_FIELDS);
        let start = swift.find("resourceFields: Set<String> = [").expect("resource fields in Swift");
        let end = start + swift[start..].find("]\n").expect("end of resource fields");
        let swift_envelope: HashSet<&str> = swift[start..end].split('"').skip(1).step_by(2).collect();
        assert_eq!(swift_envelope, RESOURCE_FIELDS.iter().copied().collect::<HashSet<_>>());
    }
}
