//! Where a new chat runs: in cmux Cloud, or on one of the person's devices
//! by its real machine id. [`resolve_chat_target`] checks the choice
//! against the daemon's own machine catalog (`machine.list` with
//! `catalog: true`; [`crate::Client::chat_target`] reads it) and the person's cloud sign-in each time it is called,
//! so there is no device list to keep in step. The CLI and the app share it.

use serde_json::Value;

/// The capability a machine advertises when it runs agent sessions (the
/// daemon's `machine_capabilities`), which a chat needs.
pub const CHAT_CAPABILITY: &str = "agent_session";

/// What a chat target selector names: `cloud`, or a device by its machine id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatTarget {
    Cloud,
    /// A device from the catalog: the local machine, or a published remote one.
    Device {
        id: String,
        local: bool,
    },
}

/// Why a selector is refused. Each names what the person can do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatTargetRefusal {
    /// An empty selector.
    Empty,
    /// No machine in the catalog has this id (names are never matched).
    UnknownDevice { id: String },
    /// The machine is in the catalog but does not run agent sessions.
    NotPermitted { id: String },
    /// The machine is known but not running now (`connecting`, `sleeping`, ...).
    Unavailable { id: String, status: String },
    /// The target needs a cmux Cloud sign-in, and the person is signed out.
    SignedOut,
}

impl ChatTargetRefusal {
    /// A stable code for scripts and the app.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Empty => "chat_target.empty",
            Self::UnknownDevice { .. } => "chat_target.unknown_device",
            Self::NotPermitted { .. } => "chat_target.not_permitted",
            Self::Unavailable { .. } => "chat_target.unavailable",
            Self::SignedOut => "chat_target.signed_out",
        }
    }
}

impl std::fmt::Display for ChatTargetRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Empty => f.write_str("name a chat target: cloud or a device's machine id"),
            Self::UnknownDevice { id } => write!(f, "no connected device has the id {id}"),
            Self::NotPermitted { id } => write!(f, "device {id} does not run agent chats"),
            Self::Unavailable { id, status } => write!(f, "device {id} is {status}"),
            Self::SignedOut => f.write_str("sign in to cmux Cloud first"),
        }
    }
}

impl std::error::Error for ChatTargetRefusal {}

/// Resolves `selector` (`cloud`, or a machine id) against `catalog`, the
/// result of `machine.list` with `catalog: true` read for this call (the
/// daemon's array of machines, or an object holding it as `machines`), and
/// whether the person is signed in to cmux Cloud now.
///
/// Cloud and every cloud-origin device need the sign-in. A device must be
/// in the catalog by its exact id, advertise [`CHAT_CAPABILITY`], and (when
/// remote) be `running`. The local machine is always running.
pub fn resolve_chat_target(
    selector: &str,
    catalog: &Value,
    signed_in: bool,
) -> Result<ChatTarget, ChatTargetRefusal> {
    let selector = selector.trim();
    if selector.is_empty() {
        return Err(ChatTargetRefusal::Empty);
    }
    if selector == "cloud" {
        return if signed_in { Ok(ChatTarget::Cloud) } else { Err(ChatTargetRefusal::SignedOut) };
    }
    let id = selector.to_owned();
    let machines = catalog_machines(catalog);
    let Some(machine) = machines.iter().find(|machine| text(machine, "id") == Some(selector))
    else {
        return Err(ChatTargetRefusal::UnknownDevice { id });
    };
    let origin = text(machine, "origin").unwrap_or("local");
    let local = origin == "local";
    if origin == "cloud" && !signed_in {
        return Err(ChatTargetRefusal::SignedOut);
    }
    let capable = machine
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|tokens| tokens.iter().any(|token| token == CHAT_CAPABILITY));
    if !capable {
        return Err(ChatTargetRefusal::NotPermitted { id });
    }
    if !local {
        let status = text(machine, "status").unwrap_or("unavailable");
        if status != "running" {
            return Err(ChatTargetRefusal::Unavailable { id, status: status.to_owned() });
        }
    }
    Ok(ChatTarget::Device { id, local })
}

/// The machine records of a catalog: the daemon answers `machine.list` with an array of them;
/// an object that holds them under `machines` is read the same way.
pub fn catalog_machines(catalog: &Value) -> &[Value] {
    match catalog {
        Value::Array(machines) => machines,
        _ => catalog.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice),
    }
}

/// A machine record's string field.
fn text<'a>(machine: &'a Value, key: &str) -> Option<&'a str> {
    machine.get(key).and_then(Value::as_str)
}

#[cfg(test)]
#[path = "chat_target_tests.rs"]
mod tests;
