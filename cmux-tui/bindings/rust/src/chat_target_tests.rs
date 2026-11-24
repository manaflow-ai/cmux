use super::*;
use serde_json::json;

fn catalog() -> Value {
    json!({"machines": [
        {"id": "machine_local", "name": "Mac", "origin": "local",
         "capabilities": ["terminal", "workspace", "agent_session"]},
        {"id": "machine_vm", "name": "vm", "origin": "cloud", "status": "running",
         "capabilities": ["terminal", "agent_session"]},
        {"id": "machine_box", "name": "box", "origin": "ssh", "status": "running",
         "capabilities": ["terminal"]},
        {"id": "machine_nap", "name": "nap", "origin": "server", "status": "sleeping",
         "capabilities": ["agent_session"]},
    ]})
}

#[test]
fn cloud_needs_a_sign_in_every_time() {
    assert_eq!(resolve_chat_target("cloud", &catalog(), true), Ok(ChatTarget::Cloud));
    assert_eq!(resolve_chat_target("cloud", &catalog(), false), Err(ChatTargetRefusal::SignedOut));
}

#[test]
fn an_unknown_device_is_refused_and_names_are_not_ids() {
    for selector in ["machine_gone", "Mac", "vm"] {
        assert_eq!(
            resolve_chat_target(selector, &catalog(), true),
            Err(ChatTargetRefusal::UnknownDevice { id: selector.into() })
        );
    }
    assert_eq!(resolve_chat_target("  ", &catalog(), true), Err(ChatTargetRefusal::Empty));
}

#[test]
fn a_device_without_agent_sessions_is_refused() {
    let refused = resolve_chat_target("machine_box", &catalog(), true).unwrap_err();
    assert_eq!(refused, ChatTargetRefusal::NotPermitted { id: "machine_box".into() });
    assert_eq!(refused.code(), "chat_target.not_permitted");
}

#[test]
fn devices_resolve_by_id_with_their_state_checked() {
    assert_eq!(
        resolve_chat_target("machine_local", &catalog(), false),
        Ok(ChatTarget::Device { id: "machine_local".into(), local: true })
    );
    assert_eq!(
        resolve_chat_target("machine_vm", &catalog(), true),
        Ok(ChatTarget::Device { id: "machine_vm".into(), local: false })
    );
    assert_eq!(
        resolve_chat_target("machine_vm", &catalog(), false),
        Err(ChatTargetRefusal::SignedOut)
    );
    assert_eq!(
        resolve_chat_target("machine_nap", &catalog(), true),
        Err(ChatTargetRefusal::Unavailable { id: "machine_nap".into(), status: "sleeping".into() })
    );
}

/// The daemon answers `machine.list` with a bare array (resource_api.rs `MachineList`).
#[test]
fn the_daemons_array_resolves_like_the_object() {
    let array = catalog()["machines"].clone();
    for selector in ["machine_local", "machine_vm", "machine_box", "machine_nap", "gone"] {
        assert_eq!(
            resolve_chat_target(selector, &array, true),
            resolve_chat_target(selector, &catalog(), true),
            "{selector}"
        );
    }
    assert_eq!(
        resolve_chat_target("machine_vm", &array, true),
        Ok(ChatTarget::Device { id: "machine_vm".into(), local: false })
    );
}

#[test]
fn an_empty_catalog_knows_no_device() {
    assert!(matches!(
        resolve_chat_target("machine_local", &json!({}), true),
        Err(ChatTargetRefusal::UnknownDevice { .. })
    ));
}
