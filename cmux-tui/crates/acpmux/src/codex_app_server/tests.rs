use super::*;
use serde_json::json;

/// What `translator()` tells the hub about audio once an app-server that
/// reports `user_agent` answered its `initialize`.
fn advertises_audio(user_agent: &str) -> bool {
    let tr = translator();
    let start = split(tr.start());
    let id = start.server[0]["id"].clone();
    split(
        tr.from_server(&json!({"jsonrpc": "2.0", "id": id, "result": {"userAgent": user_agent}})),
    );
    let reply = split(tr.from_client(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1},
    })));
    let result = reply
        .hub
        .iter()
        .find_map(|m| m.to_value().get("result").cloned())
        .expect("initialize result");
    result["agentCapabilities"]["promptCapabilities"]["audio"] == json!(true)
}

/// A Codex chat after one completed turn, with the global switch `on`: its
/// session options, and what the app-server was asked after the turn.
fn chat_after_a_turn(on: bool) -> (Value, Vec<Value>) {
    let tr = translator_with(on);
    let start = split(tr.start());
    let init = start.server[0]["id"].clone();
    let list = split(tr.from_server(
        &json!({"id": init, "result": {"userAgent": "acpmux/0.164.0 (Linux; x86_64)"}}),
    ));
    let list = list.server.iter().find(|m| m["method"] == "model/list").unwrap()["id"].clone();
    split(tr.from_server(&json!({"id": list, "result": {"data": []}})));
    let new = split(tr.from_client(
            &json!({"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": "/tmp", "mcpServers": []}}),
        ));
    let thread = new.server.iter().find(|m| m["method"] == "thread/start").unwrap()["id"].clone();
    let opened = split(tr.from_server(&json!({"id": thread, "result": {"thread": {"id": "t"}}})));
    let options = opened
        .hub
        .iter()
        .find_map(|m| m.to_value().pointer("/result/configOptions").cloned())
        .expect("session/new result");
    let prompt =
        split(tr.from_client(&json!({"jsonrpc": "2.0", "id": 2, "method": "session/prompt",
            "params": {"sessionId": "t", "prompt": [{"type": "text", "text": "fix it"}]}})));
    let turn = prompt.server.iter().find(|m| m["method"] == "turn/start").unwrap()["id"].clone();
    split(tr.from_server(&json!({"id": turn, "result": {"turn": {"id": "turn-1"}}})));
    let done = split(tr.from_server(&json!({"method": "turn/completed",
            "params": {"threadId": "t", "turn": {"id": "turn-1", "status": "completed", "items": []}}})));
    (options, done.server)
}

#[test]
fn the_global_switch_gives_codex_chats_prompt_suggestions() {
    let has_option = |o: &Value| {
        o.as_array()
            .unwrap()
            .iter()
            .any(|o| o["id"] == crate::claude_stdio::prompt_suggestions::OPTION)
    };
    let (options, asked) = chat_after_a_turn(true);
    assert!(has_option(&options), "{options}");
    assert!(asked.iter().any(|m| m["method"] == "thread/prediction/request"), "{asked:?}");
    let (options, asked) = chat_after_a_turn(false);
    assert!(!has_option(&options));
    assert!(asked.iter().all(|m| m["method"] != "thread/prediction/request"), "{asked:?}");
}

#[test]
fn a_current_codex_takes_audio_prompts() {
    assert!(advertises_audio("acpmux/0.163.0 (Mac OS 27.0.1; arm64) unknown (acpmux; 1)"));
}

#[test]
fn an_older_or_unknown_codex_does_not() {
    assert!(!advertises_audio("acpmux/0.144.0 (Mac OS 27.0.1; arm64) unknown (acpmux; 1)"));
    assert!(!advertises_audio("fake"));
}

#[test]
fn wire_redaction_hides_auth_fields_and_jwt_shaped_values() {
    let value = json!({
        "method": "account/login/start",
        "params": {"accessToken": "eyJhbGci.eyJzdWI.signature", "chatgptAccountId": "acct"},
        "result": {"authorization": "Bearer secret"}
    });
    let safe = redact(&value);
    assert_eq!(safe["params"]["accessToken"], "[REDACTED]");
    assert_eq!(safe["result"]["authorization"], "[REDACTED]");
    assert_eq!(safe["params"]["chatgptAccountId"], "acct");
    assert_eq!(
        redact(&json!("ordinary prose.with punctuation.is fine")),
        json!("ordinary prose.with punctuation.is fine")
    );
    assert_eq!(redact(&json!({"tokenCount": 3}))["tokenCount"], 3);
}

#[cfg(unix)]
#[test]
fn refresh_dispatch_preserves_id_and_rejects_account_switch() {
    let file = AccessFile {
        access_token: "access-secret".into(),
        account_id: "acct-123".into(),
        expires_at: 4_102_444_800,
        modified: std::time::SystemTime::UNIX_EPOCH,
    };
    let refreshed = AccessFile { access_token: "access-secret-2".into(), ..file.clone() };
    let mut gate = AuthGate::from_read(Ok(Some(file.clone())));
    let out = gate
        .handle_refresh(
            &json!({
                "jsonrpc": "2.0", "id": "refresh-7",
                "method": "account/chatgptAuthTokens/refresh",
                "params": {"previousAccountId": "acct-123"}
            }),
            || Ok(Some(refreshed)),
            &translator().inner,
        )
        .expect("refresh request");
    let Out::Server(reply) = &out[0] else { panic!("server response") };
    assert_eq!(reply["id"], "refresh-7");
    assert_eq!(reply["result"]["chatgptAccountId"], "acct-123");
    assert!(reply["result"].get("refreshToken").is_none());
    assert!(reply["result"].get("chatgptPlanType").is_none());

    let out = gate
        .handle_refresh(
            &json!({
                "jsonrpc": "2.0", "id": 8,
                "method": "account/chatgptAuthTokens/refresh",
                "params": {"previousAccountId": "acct-other"}
            }),
            || Ok(Some(file)),
            &translator().inner,
        )
        .expect("refresh request");
    let Out::Server(reply) = &out[0] else { panic!("server error") };
    assert_eq!(reply["id"], 8);
    assert_eq!(reply["error"]["code"], -32001);
}
#[cfg(unix)]
#[test]
fn failed_refresh_settles_held_requests() {
    let mut gate = AuthGate::from_read(Err(anyhow::anyhow!("unused")));
    gate.failed = None;
    gate.login_id = Some(json!("login"));
    gate.held_client.push(json!({"id":"queued", "method":"session/new"}));
    gate.held.push(Out::Client(json!({"id":"settled", "result":{}})));
    let out = gate
        .handle_refresh(
            &json!({
                "id":"refresh", "method":"account/chatgptAuthTokens/refresh"
            }),
            || Ok(None),
            &translator().inner,
        )
        .unwrap();
    assert!(out.iter().any(|out| matches!(out, Out::Client(v)
            if v["id"] == "queued" && v["error"]["code"] == -32001)));
    assert!(out.iter().any(|out| matches!(out, Out::Client(v)
            if v["id"] == "settled" && v["error"]["code"] == -32001)));
    assert!(out.iter().any(|out| matches!(out, Out::Server(v)
            if v["id"] == "refresh" && v["error"]["code"] == -32001)));
}

#[cfg(unix)]
#[test]
fn failed_file_read_settles_current_and_held_requests() {
    let tr = translator();
    let file = AccessFile {
        access_token: "access".into(),
        account_id: "account".into(),
        expires_at: 4_102_444_800,
        modified: std::time::SystemTime::UNIX_EPOCH,
    };
    *tr.auth.lock().unwrap() = AuthGate::from_read(Ok(Some(file.clone())));
    tr.auth.lock().unwrap().login_id = Some(json!("login"));
    tr.background().request(&json!({"id":"inflight", "method":TERMINATE,
            "params":{"threadId":"thread", "processId":"process"}}));
    assert!(
        tr.handle_client_read(&json!({"id":"queued", "method":"session/new"}), || Ok(Some(file)))
            .is_empty()
    );
    let out = tr.handle_client_read(&json!({"id":"current", "method":"session/new"}), || Ok(None));
    for id in ["queued", "current", "inflight"] {
        assert!(
            out.iter().any(|out| matches!(out, Out::Client(v)
                if v["id"] == id && v.get("error").is_some())),
            "missing reply for {id}"
        );
    }
}
/// Codex refuses a config with `[permissions]` profiles and no `default_permissions`
/// when it loads a thread's config again before each model request on a ChatGPT
/// login (workspace routing): every turn of a new chat failed with "failed to load
/// workspace requirements: invalid input parameter" (Lucas, 2026-11-05).
#[test]
fn a_new_threads_permission_profile_comes_with_its_default() {
    let tr = translator();
    // The handshake first: a session request waits for `initialize`. Codex 0.164.0's
    // user agent, as Lucas's app-server answered it.
    let init = split(tr.inner.start());
    tr.inner.from_server(&json!({"id":init.server[0]["id"], "result":{
            "userAgent":"acpmux/0.164.0 (Mac OS 26.1.0; arm64) unknown (acpmux; 0.1)"}}));
    let out = tr.inner.from_client(
        &json!({"id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}),
    );
    let start = out
        .iter()
        .find_map(|o| match o {
            Out::Server(v) if v["method"] == "thread/start" => Some(v),
            _ => None,
        })
        .expect("thread/start");
    let config = start["params"]["config"].as_object().expect("the thread's config");
    let profiles: Vec<&String> = config.keys().filter(|k| k.starts_with("permissions.")).collect();
    assert!(!profiles.is_empty(), "no permission profile: {start}");
    for key in profiles {
        let id = key.trim_start_matches("permissions.");
        assert_eq!(config.get("default_permissions"), Some(&json!(id)), "{start}");
    }
}

#[cfg(unix)]
fn running_translator() -> Arc<Translator> {
    let tr = translator();
    *tr.auth.lock().unwrap() = AuthGate::from_read(Ok(None));
    let start = split(tr.start());
    tr.inner.from_server(&json!({"id":start.server[0]["id"], "result":{}}));
    let out = tr.inner.from_client(
        &json!({"id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}),
    );
    let id = out
        .iter()
        .find_map(|o| match o {
            Out::Server(v) if v["method"] == "thread/start" => Some(v["id"].clone()),
            _ => None,
        })
        .unwrap();
    tr.inner.from_server(&json!({"id":id,"result":{"thread":{"id":"thread"}}}));
    tr.inner.from_server(
        &json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
    );
    tr
}

#[cfg(unix)]
#[test]
fn pending_login_never_queues_cancellation() {
    let tr = running_translator();
    let file = AccessFile {
        access_token: "a".into(),
        account_id: "account".into(),
        expires_at: 4_102_444_800,
        modified: std::time::SystemTime::UNIX_EPOCH,
    };
    *tr.auth.lock().unwrap() = AuthGate::from_read(Ok(Some(file.clone())));
    tr.auth.lock().unwrap().login_id = Some(json!("login"));
    let out = tr.handle_client_read(
        &json!({"method":"session/cancel","params":{"sessionId":"thread"}}),
        || Ok(Some(file)),
    );
    assert!(out.iter().any(|o| matches!(o, Out::Server(v) if v["method"] == "turn/interrupt")));
    assert!(tr.auth.lock().unwrap().held_client.is_empty());
}

#[cfg(unix)]
#[test]
fn pending_login_failure_denies_reverse_permissions_to_server() {
    for response_queued in [false, true] {
        let tr = running_translator();
        let out = tr.inner.from_server(&json!({"id":"server-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"thread","itemId":"item","command":"pwd"}}));
        let request = out
            .into_iter()
            .find_map(|o| match o {
                Out::Client(v) if v.get("id").is_some() => Some(v),
                _ => None,
            })
            .unwrap();
        let mut auth = tr.auth.lock().unwrap();
        auth.login_id = Some(json!("login"));
        if response_queued {
            auth.held_client.push(json!({"id":request["id"],"result":{"outcome":{"outcome":"selected","optionId":"accept"}}}));
        } else {
            auth.held.push(Out::Client(request));
        }
        drop(auth);
        let out = tr.from_server(&json!({"id":"login","error":{"code":-1,"message":"failed"}}));
        assert!(out.iter().any(|o| matches!(o, Out::Server(v) if v["id"] == "server-approval" && v["result"]["decision"] != "accept")));
    }
}

#[cfg(unix)]
#[test]
fn renewal_never_steals_background_termination_reply() {
    for pending in [false, true] {
        let tr = running_translator();
        tr.auth.lock().unwrap().file = Some(AccessFile {
            access_token: "a".into(),
            account_id: "account".into(),
            expires_at: 4_102_444_800,
            modified: std::time::SystemTime::UNIX_EPOCH,
        });
        let out = tr.background().request(&json!({"id":"client-stop","method":TERMINATE,"params":{"threadId":"thread","processId":"process"}})).unwrap();
        let Out::Server(request) = &out[0] else { panic!("server request") };
        tr.auth.lock().unwrap().login_id = pending.then(|| json!("login"));
        let out = tr.from_server(&json!({"id":request["id"],"result":{"terminated":true}}));
        assert!(out.iter().any(|o| matches!(o, Out::Client(v) if v["id"] == "client-stop")));
    }
}
