//! Test-only decoder from recorded `cmux-tui --jsonl session events` lines to
//! SDK session events. The SDK's own item decoder is private (reported as an
//! SDK gap), so this mirrors its wire rules for the kinds the mirror uses.

use cmux::{
    Cursor, OpaqueId, ResetReason, ResourceChange, ResourceEntitySnapshot as V, ResourceKind,
    ResourceReference as R, SessionDeltaEvent, SessionEvent, SessionSnapshotEvent,
};
use serde_json::Value;

fn de<T: serde::de::DeserializeOwned>(value: &Value) -> T {
    serde_json::from_value(value.clone()).unwrap_or_else(|e| panic!("decode {value}: {e}"))
}

fn decimal(value: &Value) -> u64 {
    value.as_str().expect("decimal string").parse().expect("decimal")
}

fn id<I: OpaqueId>(value: &str) -> I {
    I::parse(value).expect("id")
}

/// Decodes one recorded stream envelope (or a bare item) into an event.
pub fn event(line: &str) -> SessionEvent {
    let envelope: Value = serde_json::from_str(line).expect("json line");
    let item = envelope.get("item").unwrap_or(&envelope);
    let cursor: Cursor = de(&item["cursor"]);
    match item["kind"].as_str().expect("kind") {
        "snapshot" => SessionEvent::Snapshot(SessionSnapshotEvent {
            cursor,
            reset_reason: match item.get("reset_reason").and_then(Value::as_str) {
                Some("initial") => Some(ResetReason::Initial),
                Some("generation_changed") => Some(ResetReason::GenerationChanged),
                Some("cursor_expired") => Some(ResetReason::CursorExpired),
                _ => None,
            },
            snapshot: de(&item["snapshot"]),
        }),
        "delta" => SessionEvent::Delta(SessionDeltaEvent {
            cursor,
            previous_revision: decimal(&item["previous_revision"]),
            revision: decimal(&item["revision"]),
            changes: item["changes"].as_array().expect("changes").iter().map(change).collect(),
        }),
        other => panic!("unexpected kind {other}"),
    }
}

fn change(value: &Value) -> ResourceChange {
    let sequence = value["sequence"].as_u64().expect("sequence") as u32;
    let raw_id = value["id"].as_str().expect("id");
    let (resource, reference) = match value["resource"].as_str().expect("resource") {
        "session" => (ResourceKind::Session, R::Session(id(raw_id))),
        "workspace" => (ResourceKind::Workspace, R::Workspace(id(raw_id))),
        "screen" => (ResourceKind::Screen, R::Screen(id(raw_id))),
        "pane" => (ResourceKind::Pane, R::Pane(id(raw_id))),
        "tab" => (ResourceKind::Tab, R::Tab(id(raw_id))),
        "terminal" => (ResourceKind::Terminal, R::Terminal(id(raw_id))),
        "browser" => (ResourceKind::Browser, R::Browser(id(raw_id))),
        "client" => (ResourceKind::Client, R::Client(id(raw_id))),
        other => panic!("fixture resource {other} not supported"),
    };
    match value["kind"].as_str().expect("kind") {
        "delete" => ResourceChange::Delete { sequence, resource, id: reference },
        "upsert" => {
            let v = &value["value"];
            let entity = match resource {
                ResourceKind::Session => V::Session(de(v)),
                ResourceKind::Workspace => V::Workspace(de(v)),
                ResourceKind::Screen => V::Screen(de(v)),
                ResourceKind::Pane => V::Pane(de(v)),
                ResourceKind::Tab => V::Tab(de(v)),
                ResourceKind::Terminal => V::Terminal(de(&patch_detached_terminal(v))),
                ResourceKind::Browser => V::Browser(de(v)),
                ResourceKind::Client => V::Client(de(v)),
                _ => unreachable!(),
            };
            ResourceChange::Upsert { sequence, resource, id: reference, value: entity }
        }
        other => panic!("change kind {other}"),
    }
}

/// The pinned daemon sends a terminal whose last tab closed without
/// `lifecycle` (`"tab_id":null,"tab_ids":[]`), which the pinned SDK's
/// `TerminalSnapshot` requires, so the real stream fails to decode that
/// delta (reported upstream; the client resyncs). Fill it from `running`
/// so the mirror tests can replay the rest of the recording.
pub fn patch_detached_terminal(value: &Value) -> Value {
    let mut value = value.clone();
    if let Some(object) = value.as_object_mut()
        && !object.contains_key("lifecycle")
    {
        let running = object.get("running").and_then(Value::as_bool).unwrap_or(false);
        object
            .insert("lifecycle".into(), Value::from(if running { "running" } else { "launching" }));
    }
    value
}

/// The recorded session: initial snapshot, workspace "alpha" created
/// (rev 1), its terminal titled (2), renamed to "beta" (3), workspace
/// "gamma" created (4) and closed (5).
pub const SESSION_EVENTS: &str = include_str!("../tests/fixtures/session-events.jsonl");

pub fn recorded() -> Vec<SessionEvent> {
    SESSION_EVENTS.lines().filter(|l| !l.trim().is_empty()).map(event).collect()
}
