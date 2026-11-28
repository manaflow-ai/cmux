use super::*;

#[test]
fn local_route_keys_are_redacted_without_becoming_cloud_credentials() {
    for name in [
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "XAI_API_KEY",
        crate::agent_credentials::CHATGPT_TOKEN,
    ] {
        let key = "fixture-local-provider-key";
        let spec: SpawnSpec = serde_json::from_value(serde_json::json!({
            "session_id": "chat",
            "program": "fixture",
            "args": [],
            "env": [[name, key], [crate::agent_credentials::LOCAL_REDACTION, name]],
            "cwd": "/",
            "hosts_dir": "/",
            "socket": "/unused",
            "buffer_cap": 1024
        }))
        .unwrap();
        let mut entry = Entry::Err { line: format!("provider refused {key}") };
        redact_launch_key(&mut entry, spec.launch_key(spec.launch_key_index()).unwrap());
        assert_eq!(entry, Entry::Err { line: "provider refused [redacted]".into() });
        let process_env =
            format!("{}={name}\0{name}={key}\0", crate::agent_credentials::LOCAL_REDACTION);
        assert!(crate::agent_credentials::recovered(process_env.as_bytes()).is_none());
    }
}

#[test]
fn local_kimi_grants_are_redacted_without_a_cloud_recovery_marker() {
    let grant = "fixture-kimi-grant";
    let spec: SpawnSpec = serde_json::from_value(serde_json::json!({
        "session_id": "chat",
        "program": "opencode",
        "args": [],
        "env": [[crate::byo_endpoint::OPENAI_KEY_ENV, grant]],
        "cwd": "/",
        "hosts_dir": "/",
        "socket": "/unused",
        "buffer_cap": 1024
    }))
    .unwrap();
    let key = spec.launch_key(spec.launch_key_index()).expect("the host registers the grant");
    let mut entry = Entry::Err { line: format!("provider refused {grant}") };
    redact_launch_key(&mut entry, key);
    assert_eq!(entry, Entry::Err { line: "provider refused [redacted]".into() });
}

#[test]
fn endpoint_launch_credentials_are_redacted_from_host_entries() {
    let token = "fixture-provider-key";
    let mut line = Entry::Err { line: format!("provider refused {token}") };
    let mut event = Entry::In {
        msg: serde_json::json!({"params": {"text": token, token: "provider metadata"}}),
    };
    for entry in [&mut line, &mut event] {
        redact_launch_key(entry, token);
        let json = serde_json::to_string(entry).unwrap();
        assert!(!json.contains(token));
        assert!(json.contains("[redacted]"));
    }
}
