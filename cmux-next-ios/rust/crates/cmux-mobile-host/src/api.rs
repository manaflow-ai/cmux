//! `api`: the phone's method list, served by this Mac (cmux-next-ios/contract/README.md,
//! "App-level API").
//!
//! Leo: "well clearly we need to be able to support the multiple versions as it goes".
//! A phone asks `api` what this Mac answers instead of guessing from a version number:
//!
//! - `{"op": "list"}`: every method this Mac serves to a phone (link services, daemon
//!   commands and events, acpmux methods), with since and capability, plus a digest.
//! - `{"op": "describe", "method": "daemon/list-workspaces"}`: that method's request and
//!   response JSON Schemas with every type they reach.
//! - `{"op": "llms"}`: the list as text (`{"text": ...}`).
//!
//! A Mac from before this service replies `unknown_service`; the phone then falls back to
//! the `version` service's capabilities (`cmux_mobile_api::Discovery::legacy`).
//!
//! The list itself is `cmux-mobile-api/phone-api.json`, generated from the protocol IRs
//! and the allow lists below by the `phone_api_contract` test, which also fails when a
//! method changes without a compat rule.

use serde_json::{Value, json};

use cmux_mobile_api::lower::LinkService;
use cmux_mobile_link::names;

/// The `version` capability that says this Mac serves `api`.
pub const CAPABILITY: &str = names::API_DESCRIBE;

/// Every link service hostd's `serve_channel` answers (services.rs), with the capability that
/// says this Mac serves it now. `None`: every hostd with `api` serves it, or it has more than
/// one capability (its own doc says which).
pub const LINK_SERVICES: &[LinkService] = &[
    LinkService {
        name: "api",
        capability: Some(names::API_DESCRIBE),
        meaning: "This list: `{op: list|describe|llms}`.",
    },
    LinkService {
        name: "auth",
        capability: None,
        meaning: "Pairing and the link's proof of who the phone is.",
    },
    LinkService { name: "echo", capability: None, meaning: "Bytes back, for path checks." },
    LinkService {
        name: "daemon",
        capability: None,
        meaning: "Lines to the cmux-tui daemon; every `daemon/*` method rides it. Args: session, pseq, viewport_sync, strict.",
    },
    LinkService { name: "chief", capability: None, meaning: "Lines to the Chief's conversation owner." },
    LinkService {
        name: "acpmux",
        capability: None,
        meaning: "JSON-RPC to this Mac's acpmux; every `acpmux/*` method rides it.",
    },
    LinkService {
        name: "cloud-directory",
        capability: Some(names::CLOUD_DIRECTORY),
        meaning: "The owner's Cloud machines.",
    },
    LinkService {
        name: "catch-up",
        capability: None,
        meaning: "What changed since the phone's last cursor.",
    },
    LinkService {
        name: "cloud-acpmux",
        capability: Some(names::CLOUD_ACPMUX),
        meaning: "acpmux on one of the owner's Cloud machines.",
    },
    LinkService { name: "file", capability: None, meaning: "One file's bytes." },
    LinkService {
        name: "file-preview",
        capability: Some(names::FILE_PREVIEW),
        meaning: "A file's size frame, then its bytes.",
    },
    LinkService { name: "upload", capability: None, meaning: "A file from the phone to the Mac." },
    LinkService {
        name: "bundle",
        capability: Some(names::BUNDLE),
        meaning: "Sealed content-defined chunks (RFD 0142 R7).",
    },
    LinkService { name: "version", capability: None, meaning: "`{hostd, link, capabilities}`." },
    LinkService {
        name: "lan",
        capability: Some(crate::lan::CAPABILITY),
        meaning: "Enroll for the LAN direct path.",
    },
    LinkService { name: "machine", capability: None, meaning: "A machine's grants (machine links only)." },
    LinkService {
        name: "needs-you",
        capability: Some(names::NEEDS_YOU),
        meaning: "Chats waiting on the person.",
    },
    LinkService {
        name: "pair-requests",
        capability: Some(names::PAIR_REQUESTS),
        meaning: "Other devices asking to pair.",
    },
    LinkService { name: "appearance", capability: Some(names::APPEARANCE), meaning: "The Mac's theme." },
    LinkService {
        name: "appearance-wallpaper",
        capability: Some(names::APPEARANCE),
        meaning: "The Mac's wallpaper image.",
    },
    LinkService {
        name: "live-code",
        capability: None,
        meaning: "Swift live code patches (cmux Dev phones).",
    },
    LinkService {
        name: "browser",
        capability: Some(names::BROWSER_STREAM),
        meaning: "A streamed browser tab (cmux.rd/1).",
    },
    LinkService {
        name: "surface",
        capability: None,
        meaning: "A streamed simulator, Cloud desktop or Mac display: surface-stream-v1, cloud-desktop-v1, mac-display-v1.",
    },
    LinkService {
        name: "localhost",
        capability: Some(names::LOCALHOST_FORWARD),
        meaning: "A port on the Mac's loopback.",
    },
    LinkService { name: "try-pr", capability: Some(names::TRY_PR), meaning: "Try a pull request's build." },
    LinkService {
        name: "site-data",
        capability: Some(names::SITE_DATA_HANDOFF),
        meaning: "A tab's cookies and storage for its own site (RFD 0089).",
    },
    LinkService {
        name: cmux_phone_page::SERVICE,
        capability: Some(names::PHONE_PAGE),
        meaning: "Agents' browser.page.* verbs on a phone tab.",
    },
    LinkService {
        name: "phone-frames",
        capability: Some(names::PHONE_FRAMES),
        meaning: "Frames from the phone's own tabs.",
    },
    LinkService { name: "tabs", capability: Some(names::TAB_SNAPSHOTS), meaning: "Tab snapshots." },
];

/// The acpmux methods the phone sends or reads on `acpmux` (and `cloud-acpmux`). The
/// `phone_api_contract` test fails when the Swift app names one not here.
pub const PHONE_ACPMUX_METHODS: &[&str] = &[
    "initialize",
    "session/new",
    "session/prompt",
    "session/cancel",
    "session/fork",
    "session/set_config_option",
    "session/set_model",
    "session/set_mode",
    "session/update",
    "acp.session.fork",
    "_acpmux/archive",
    "_acpmux/attach",
    "_acpmux/attachment",
    "_acpmux/bookmark_get",
    "_acpmux/bookmark_set",
    "_acpmux/chunk",
    "_acpmux/event",
    "_acpmux/events",
    "_acpmux/file_put_begin",
    "_acpmux/file_put_cancel",
    "_acpmux/file_put_chunk",
    "_acpmux/file_put_finish",
    "_acpmux/handoff_discard",
    "_acpmux/handoff_prepare",
    "_acpmux/handoff_start",
    "_acpmux/harnesses",
    "_acpmux/info",
    "_acpmux/lagged",
    "_acpmux/models",
    "_acpmux/permission_chat_revoke",
    "_acpmux/permission_groups",
    "_acpmux/permission_pending",
    "_acpmux/permission_respond",
    "_acpmux/queue_edit",
    "_acpmux/queue_remove",
    "_acpmux/retry",
    "_acpmux/secret_submit",
    "_acpmux/session_changed",
    "_acpmux/session_patch",
    "_acpmux/sessions",
    "_acpmux/status",
    "_acpmux/watch",
];

/// Daemon-service commands hostd answers itself (policy.rs), with their request schemas,
/// since the daemon's `sdk-schema.json` does not know them.
pub fn host_daemon_commands() -> Vec<(&'static str, Value)> {
    vec![(
        "notification-reply",
        json!({
            "type": "object",
            "properties": {
                "notification": {"type": "integer", "format": "uint64", "minimum": 0},
                "text": {
                    "type": "string",
                    "minLength": 1,
                    "description": format!("At most {} bytes.", crate::policy::NOTIFICATION_REPLY_MAX_BYTES),
                },
                "reply_id": {"type": "string", "description": "8 to 64 letters, digits or dashes."},
            },
            "required": ["notification", "text"],
            "additionalProperties": false,
        }),
    )]
}

/// Whether this hostd serves `method` now, given its live `version` capabilities.
pub fn served(method: &Value, capabilities: &[&str]) -> bool {
    let link = method["name"].as_str().is_some_and(|n| n.starts_with("link/"));
    match method.get("capability").and_then(Value::as_str) {
        Some(cap) if link => capabilities.contains(&cap),
        // Daemon and acpmux methods: the daemon or acpmux behind this Mac answers them;
        // their own capabilities are the daemon's to advertise (`identify`).
        _ => true,
    }
}

/// The reply to one `api` request, or a refusal `(code, reason)`.
pub fn answer(args: &Value, capabilities: &[&str]) -> Result<Value, (&'static str, String)> {
    let contract = cmux_mobile_api::contract();
    match args.get("op").and_then(Value::as_str).unwrap_or("list") {
        "list" => Ok(contract.list(|m| served(m, capabilities))),
        "describe" => {
            let Some(name) = args.get("method").and_then(Value::as_str) else {
                return Err(("bad_request", "describe needs a method".into()));
            };
            contract.describe(name).ok_or(("not_found", format!("no method {name}")))
        }
        "llms" => Ok(json!({ "text": contract.llms_txt(|m| served(m, capabilities)) })),
        op => Err(("bad_request", format!("no api op {op}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_drops_unadvertised_link_services() {
        let reply = answer(&json!({"op": "list"}), &[CAPABILITY]).unwrap();
        let names: Vec<&str> =
            reply["methods"].as_array().unwrap().iter().filter_map(|m| m["name"].as_str()).collect();
        assert!(names.contains(&"link/api"));
        assert!(names.contains(&"link/version"));
        assert!(!names.contains(&"link/browser"));
        assert!(reply["digest"].as_str().unwrap().starts_with("fnv1a64:"));
    }

    #[test]
    fn describe_and_errors() {
        assert!(answer(&json!({"op": "describe", "method": "link/version"}), &[]).is_ok());
        assert_eq!(answer(&json!({"op": "describe", "method": "nope"}), &[]).unwrap_err().0, "not_found");
        assert_eq!(answer(&json!({"op": "describe"}), &[]).unwrap_err().0, "bad_request");
        assert_eq!(answer(&json!({"op": "zap"}), &[]).unwrap_err().0, "bad_request");
        assert!(
            answer(&json!({"op": "llms"}), &[]).unwrap()["text"].as_str().unwrap().contains("link/version")
        );
    }
}
