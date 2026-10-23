//! MCP elicitation asked as a question (`elicitation.rs`).

use super::*;

fn ask(request: Value) -> Value {
    let mut request = request;
    request["subtype"] = json!("elicitation");
    json!({"type": "control_request", "request_id": "e1", "request": request})
}

/// The permission request the translator raised, and its ACP id.
async fn asked(t: &Translator, line: &Value) -> Option<(Id, Value)> {
    t.inbound(line).await.into_iter().find_map(|m| match m {
        Message::Request { id, method: m, params: Some(p) }
            if m == method::SESSION_REQUEST_PERMISSION =>
        {
            Some((id, p))
        }
        _ => None,
    })
}

/// The hub's answer to request `id`, then the line Claude Code reads. The hub
/// lifts an outcome's `_meta` (the answers) beside it (hub/permissions.rs).
async fn answer(t: &Translator, id: Id, mut outcome: Value) -> Value {
    let meta = outcome.as_object_mut().and_then(|o| o.remove("_meta"));
    let mut result = json!({"outcome": outcome});
    if let Some(meta) = meta {
        result["_meta"] = meta;
    }
    let msg = Message::Response { id, result: Some(result), error: None };
    match t.outbound(&msg).await {
        Outbound::Lines(lines) => lines.into_iter().next().expect("a reply line"),
        _ => panic!("expected a reply line"),
    }
}

fn deploy_form() -> Value {
    ask(json!({
        "mcp_server_name": "deployer",
        "display_name": "Deployer",
        "message": "Where should this deploy go?",
        "mode": "form",
        "requested_schema": {
            "type": "object",
            "properties": {
                "region": {"type": "string", "title": "Region", "oneOf": [
                    {"const": "us-east-1", "title": "US East"},
                    {"const": "eu-west-1", "title": "EU West"}
                ]},
                "replicas": {"type": "integer", "title": "Replicas"},
                "canary": {"type": "boolean", "title": "Canary"},
                "tags": {"type": "array", "title": "Tags", "items": {"enum": ["web", "api, v2"]}},
                "note": {"type": "string", "title": "Note"}
            },
            "required": ["region", "replicas", "canary"]
        },
        "property_order": ["region", "replicas", "canary", "tags", "note"]
    }))
}

#[tokio::test]
async fn a_form_is_asked_as_a_question_only_a_person_answers() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (_, p) = asked(&t, &deploy_form()).await.expect("a question");
    let question = &p["toolCall"]["_meta"]["acpmux"]["question"];
    assert_eq!(question["harness"], "claude");
    assert_eq!(question["agent"], "Deployer");
    let items = question["items"].as_array().expect("items");
    // In the server's own order, the message leading the first.
    let prompts: Vec<&str> = items.iter().filter_map(|i| i["prompt"].as_str()).collect();
    assert_eq!(
        prompts,
        ["Where should this deploy go? — Region", "Replicas", "Canary", "Tags", "Note"]
    );
    assert_eq!(
        items[0]["options"],
        json!([{"id": "US East", "label": "US East"}, {"id": "EU West", "label": "EU West"}])
    );
    assert_eq!(items[0]["allowsOther"], false);
    assert_eq!(items[1]["options"], json!([]));
    assert_eq!(items[1]["allowsOther"], true);
    assert_eq!(items[2]["options"][0]["label"], "Yes");
    assert_eq!(items[3]["multiSelect"], true);
    // An optional field can be left out.
    assert_eq!(
        items[3]["options"].as_array().and_then(|o| o.last()).map(|o| o["label"].clone()),
        Some(json!("No answer"))
    );
    // Not AskUserQuestion: no session above this one may answer it (`hub/questions.rs`).
    assert_ne!(p["toolCall"]["_meta"]["claude"]["tool"], "AskUserQuestion");
    let kinds: Vec<&str> =
        p["options"].as_array().into_iter().flatten().filter_map(|o| o["kind"].as_str()).collect();
    assert_eq!(kinds, ["allow_once", "reject_once"]);
}

#[tokio::test]
async fn submit_sends_the_answers_as_the_forms_content() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let answers = json!({
        "Where should this deploy go? — Region": "EU West",
        "Replicas": " 3 ",
        "Canary": "No",
        "Tags": "web, api, v2",
        "Note": "No answer",
    });
    let line = answer(
        &t,
        id,
        json!({"outcome": "selected", "optionId": "allow_once",
        "_meta": {"updatedInput": {"answers": answers}}}),
    )
    .await;
    assert_eq!(line["type"], "control_response");
    assert_eq!(line["response"]["request_id"], "e1");
    assert_eq!(
        line["response"]["response"],
        json!({"action": "accept", "content": {
            "region": "eu-west-1", "replicas": 3, "canary": false, "tags": ["web", "api, v2"]
        }})
    );
}

#[tokio::test]
async fn a_number_that_does_not_parse_is_left_out() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let result = json!({
        "outcome": {"outcome": "selected", "optionId": "allow_once"},
        "_meta": {"updatedInput": {"answers": {"Replicas": "x"}}},
    });
    let msg = Message::Response { id, result: Some(result), error: None };
    let Outbound::Lines(lines) = t.outbound(&msg).await else { panic!("expected lines") };
    // A number that does not parse is left out for the server to refuse.
    assert_eq!(lines[0]["response"]["response"], json!({"action": "accept", "content": {}}));
}

#[tokio::test]
async fn skip_declines_and_a_stopped_turn_cancels() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let line = answer(&t, id, json!({"outcome": "selected", "optionId": "reject_once"})).await;
    assert_eq!(line["response"]["response"], json!({"action": "decline"}));
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let line = answer(&t, id, json!({"outcome": "cancelled"})).await;
    assert_eq!(line["response"]["response"], json!({"action": "cancel"}));
}

#[tokio::test]
async fn a_single_field_asks_the_message_under_the_servers_name() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = ask(json!({
        "mcp_server_name": "github",
        "message": "Which repository?",
        "requested_schema": {"type": "object", "properties": {"repo": {"type": "string", "enum": ["a", "b"], "enumNames": ["Alpha", "Beta"]}}, "required": ["repo"]}
    }));
    let (id, p) = asked(&t, &line).await.expect("a question");
    let item = &p["toolCall"]["_meta"]["acpmux"]["question"]["items"][0];
    assert_eq!(item["prompt"], "Which repository?");
    assert_eq!(item["header"], "github");
    let answers = json!({"Which repository?": "Beta"});
    let line = answer(
        &t,
        id,
        json!({"outcome": "selected", "optionId": "allow_once",
        "_meta": {"updatedInput": {"answers": answers}}}),
    )
    .await;
    assert_eq!(line["response"]["response"]["content"], json!({"repo": "b"}));
}

#[tokio::test]
async fn url_mode_and_nested_schemas_keep_the_unsupported_reply() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let url = ask(
        json!({"mcp_server_name": "s", "message": "Sign in", "mode": "url", "url": "https://example.com"}),
    );
    let nested = ask(json!({"mcp_server_name": "s", "message": "m", "requested_schema": {
        "type": "object", "properties": {"x": {"type": "object", "properties": {}}}
    }}));
    for line in [url, nested] {
        assert!(asked(&t, &line).await.is_none());
        let replies = t.take_stdin_replies().await;
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0]["response"]["subtype"], "error");
        assert_eq!(replies[0]["response"]["request_id"], "e1");
    }
}
