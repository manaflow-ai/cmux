use cmux_client::{
    COMMANDS, EVENTS, MUX_PROTOCOL_VERSION, Nullable, Optional, SDK_SCHEMA_VERSION,
    SetClientInfoRequest, Tree, UnknownEvent, decode_event,
};

#[test]
fn generated_protocol_inventory_is_complete() {
    assert_eq!(SDK_SCHEMA_VERSION, 2);
    assert_eq!(MUX_PROTOCOL_VERSION, 10);
    assert_eq!(COMMANDS.len(), 83);
    assert_eq!(EVENTS.len(), 44);

    let mut commands = COMMANDS.iter().map(|command| command.name).collect::<Vec<_>>();
    commands.sort_unstable();
    commands.dedup();
    assert_eq!(commands.len(), COMMANDS.len());

    let mut events = EVENTS.iter().map(|event| event.name).collect::<Vec<_>>();
    events.sort_unstable();
    events.dedup();
    assert_eq!(events.len(), EVENTS.len());
}

#[test]
fn consumer_can_distinguish_missing_null_and_value() {
    let missing = SetClientInfoRequest::default();
    assert_eq!(serde_json::to_value(missing).unwrap(), serde_json::json!({}));

    let null = SetClientInfoRequest { name: Optional::Null, kind: Optional::Null };
    assert_eq!(
        serde_json::to_value(null).unwrap(),
        serde_json::json!({"name": null, "kind": null})
    );

    let value = SetClientInfoRequest {
        name: Optional::Value("phone".to_string()),
        kind: Optional::Value("frontend".to_string()),
    };
    assert_eq!(
        serde_json::to_value(value).unwrap(),
        serde_json::json!({"name": "phone", "kind": "frontend"})
    );
}

#[test]
fn required_nullable_accessors_preserve_explicit_null() {
    let value: Nullable<String> = Some("agent".to_string()).into();
    assert!(!value.is_null());
    assert_eq!(value.as_ref().into_option().map(String::as_str), Some("agent"));
    assert_eq!(value.as_deref().into_option(), Some("agent"));

    let null: Nullable<String> = None.into();
    assert!(null.is_null());
    assert_eq!(serde_json::to_value(&null).unwrap(), serde_json::Value::Null);

    #[derive(serde::Deserialize)]
    struct RequiredField {
        value: Nullable<String>,
    }

    assert!(serde_json::from_value::<RequiredField>(serde_json::json!({})).is_err());
    let decoded: RequiredField =
        serde_json::from_value(serde_json::json!({"value": null})).unwrap();
    assert!(decoded.value.is_null());
}

#[test]
fn consumer_receives_unknown_events_without_decode_failure() {
    let raw = serde_json::json!({"event": "future-event", "answer": 42});
    let event = decode_event(raw.clone());
    assert!(matches!(
        event,
        cmux_client::Event::Unknown(UnknownEvent {
            name: Some(name),
            raw: actual,
            decode_error: None,
        }) if name == "future-event" && actual == raw
    ));
}

#[test]
fn consumer_can_find_surface_context_and_strict_active_live_pty() {
    let tree = topology_fixture();

    let found = tree.find_surface(42).expect("surface context");
    assert_eq!(found.workspace.name, "active workspace");
    assert_eq!(found.screen.id, 20);
    assert_eq!(found.pane.id, 30);
    assert_eq!(found.tab.title, "active pty");
    assert!(tree.find_surface(999).is_none());

    let active = tree.active_live_pty().expect("active live PTY");
    assert_eq!(active.tab.surface, 42);

    let mut browser_active = tree.clone();
    browser_active.workspaces[1].screens[1].active_pane = 31;
    assert!(
        browser_active.active_live_pty().is_none(),
        "a browser active tab must not fall back to another live PTY"
    );
}

fn topology_fixture() -> Tree {
    serde_json::from_value(serde_json::json!({
        "workspaces": [
            {
                "active": false,
                "id": 1,
                "name": "inactive workspace",
                "screens": [{
                    "active": true,
                    "active_pane": 3,
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "name": null,
                    "panes": [{
                        "active_tab": 0,
                        "id": 3,
                        "name": null,
                        "tabs": [{
                            "browser_source": null,
                            "dead": false,
                            "kind": "pty",
                            "name": null,
                            "size": null,
                            "surface": 7,
                            "title": "inactive pty"
                        }]
                    }],
                    "zoomed_pane": null
                }]
            },
            {
                "active": true,
                "id": 10,
                "name": "active workspace",
                "screens": [
                    {
                        "active": false,
                        "active_pane": 12,
                        "id": 11,
                        "layout": {"type": "leaf", "pane": 12},
                        "name": null,
                        "panes": [{
                            "active_tab": 0,
                            "id": 12,
                            "name": null,
                            "tabs": [{
                                "browser_source": null,
                                "dead": false,
                                "kind": "pty",
                                "name": null,
                                "size": null,
                                "surface": 17,
                                "title": "inactive screen pty"
                            }]
                        }],
                        "zoomed_pane": null
                    },
                    {
                        "active": true,
                        "active_pane": 30,
                        "id": 20,
                        "layout": {"type": "leaf", "pane": 30},
                        "name": "agents",
                        "panes": [
                            {
                                "active_tab": 1,
                                "id": 30,
                                "name": "runner",
                                "tabs": [
                                    {
                                        "browser_source": null,
                                        "dead": false,
                                        "kind": "pty",
                                        "name": null,
                                        "size": null,
                                        "surface": 41,
                                        "title": "inactive tab"
                                    },
                                    {
                                        "browser_source": null,
                                        "dead": false,
                                        "kind": "pty",
                                        "name": null,
                                        "size": null,
                                        "surface": 42,
                                        "title": "active pty"
                                    }
                                ]
                            },
                            {
                                "active_tab": 0,
                                "id": 31,
                                "name": null,
                                "tabs": [{
                                    "browser_source": "launched",
                                    "dead": false,
                                    "kind": "browser",
                                    "name": null,
                                    "size": null,
                                    "surface": 43,
                                    "title": "browser"
                                }]
                            }
                        ],
                        "zoomed_pane": null
                    }
                ]
            }
        ]
    }))
    .expect("valid generated tree")
}
