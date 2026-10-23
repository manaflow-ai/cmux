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
                "tags": {"type": "array", "title": "Tags", "items": {"enum": ["web", "api"], "enumNames": ["Web", "API v2"]}},
                "note": {"type": "string", "title": "Note"}
            },
            "required": ["region", "replicas", "canary", "note"]
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
        "Tags": "Web, API v2, No answer",
        // A required string takes typed "No answer" as it is.
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
            "region": "eu-west-1", "replicas": 3, "canary": false, "tags": ["web", "api"],
            "note": "No answer"
        }})
    );
}

/// Answers that are not the form's never reach the server as content.
#[tokio::test]
async fn an_answer_the_form_does_not_offer_cancels() {
    let good = json!({
        "Where should this deploy go? — Region": "EU West", "Replicas": "3", "Canary": "No",
        "Tags": "Web", "Note": "Ship it",
    });
    let bad = [
        ("Replicas", "x"),                                 // a number that does not parse
        ("Where should this deploy go? — Region", "Mars"), // a choice not offered
        ("Canary", "Maybe"),                               // neither yes nor no
        ("Tags", "Web, Web"),                              // chosen twice
        ("Tags", "Web, Mars"),                             // one not offered
        ("Where should this deploy go? — Region", "No answer"), // required, left out
    ];
    for (prompt, value) in bad {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
        let mut answers = good.clone();
        answers[prompt] = json!(value);
        let outcome = json!({"outcome": "selected", "optionId": "allow_once",
            "_meta": {"updatedInput": {"answers": answers}}});
        let line = answer(&t, id, outcome).await;
        assert_eq!(line["response"]["response"], json!({"action": "cancel"}), "{prompt}={value}");
    }
}

/// Claude Code withdrew the form (its tool call ended): the form is
/// forgotten, the hub is sent nothing, and an answer that still comes to its
/// card sends Claude Code nothing, so nothing waits on it.
#[tokio::test]
async fn a_withdrawn_form_is_forgotten() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let withdraw = json!({"type": "control_cancel_request", "request_id": "e1"});
    assert!(t.inbound(&withdraw).await.is_empty());
    let late = Message::Response {
        id,
        result: Some(json!({"outcome": {"outcome": "selected", "optionId": "reject_once"}})),
        error: None,
    };
    let Outbound::Lines(lines) = t.outbound(&late).await else { panic!("expected lines") };
    assert!(lines.is_empty(), "{lines:?}");
    assert!(t.take_stdin_replies().await.is_empty());
    // A withdrawal of a request it does not know is ignored.
    assert!(t.inbound(&withdraw).await.is_empty());
}

/// The hub answered before Claude Code withdrew the form: the answer goes out
/// once, and the withdrawal after it changes nothing.
#[tokio::test]
async fn an_answer_before_the_withdrawal_goes_out_once() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, _) = asked(&t, &deploy_form()).await.expect("a question");
    let line =
        answer(&t, id.clone(), json!({"outcome": "selected", "optionId": "reject_once"})).await;
    assert_eq!(line["response"]["response"], json!({"action": "decline"}));
    let withdraw = json!({"type": "control_cancel_request", "request_id": "e1"});
    assert!(t.inbound(&withdraw).await.is_empty());
    assert!(t.take_stdin_replies().await.is_empty());
    let again = Message::Response {
        id,
        result: Some(json!({"outcome": {"outcome": "selected", "optionId": "allow_once"}})),
        error: None,
    };
    let Outbound::Lines(lines) = t.outbound(&again).await else { panic!("expected lines") };
    assert!(lines.is_empty(), "{lines:?}");
}

/// "No answer" leaves an optional number out: typed, it is no number anyway.
/// A form with an optional string is not asked, since its typed "No answer"
/// could not be told from the option (the card answers with one string).
#[tokio::test]
async fn no_answer_is_offered_only_where_it_cannot_be_typed_text() {
    let form = |kind: &str| {
        ask(json!({"mcp_server_name": "s", "message": "m", "requested_schema": {
            "type": "object", "properties": {"x": {"type": kind, "title": "X"}}}}))
    };
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (id, p) = asked(&t, &form("integer")).await.expect("a question");
    let item = &p["toolCall"]["_meta"]["acpmux"]["question"]["items"][0];
    assert_eq!(item["options"], json!([{"id": "No answer", "label": "No answer"}]));
    let outcome = json!({"outcome": "selected", "optionId": "allow_once",
        "_meta": {"updatedInput": {"answers": {"m": "No answer"}}}});
    let line = answer(&t, id, outcome).await;
    assert_eq!(line["response"]["response"], json!({"action": "accept", "content": {}}));
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    assert!(asked(&t, &form("string")).await.is_none());
    assert_eq!(t.take_stdin_replies().await[0]["response"]["subtype"], "error");
}

/// Answers are keyed by prompt: a repeated prompt gets its field's key, and a
/// form where even that repeats is not asked (it could never be submitted).
#[tokio::test]
async fn every_prompt_is_distinct() {
    let titled = |titles: [&str; 3]| {
        let property = |title: &str| json!({"type": "string", "title": title});
        ask(json!({"mcp_server_name": "s", "property_order": ["a", "b", "c"],
            "requested_schema": {"type": "object", "required": ["a", "b", "c"], "properties": {
                "a": property(titles[0]), "b": property(titles[1]), "c": property(titles[2])}}}))
    };
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (_, p) = asked(&t, &titled(["P", "P", "Q"])).await.expect("a question");
    let items = p["toolCall"]["_meta"]["acpmux"]["question"]["items"].as_array().cloned();
    let prompts: Vec<Value> = items.into_iter().flatten().map(|i| i["prompt"].clone()).collect();
    assert_eq!(prompts, [json!("P"), json!("P (b)"), json!("Q")]);
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    assert!(asked(&t, &titled(["P (c)", "P", "P"])).await.is_none());
    assert_eq!(t.take_stdin_replies().await[0]["response"]["subtype"], "error");
}

/// A form whose answers could not be read back exactly is not asked.
#[tokio::test]
async fn ambiguous_forms_keep_the_unsupported_reply() {
    let field = |property: Value, order: Value| {
        ask(json!({"mcp_server_name": "s", "message": "m", "property_order": order,
            "requested_schema": {"type": "object", "required": ["b"],
                "properties": {"a": property, "b": {"type": "string"}}}}))
    };
    let forms = [
        // A multi-select label holding the join.
        field(json!({"type": "array", "items": {"enum": ["x", "x, y", "y"]}}), json!(["a", "b"])),
        // An optional choice that is the "No answer" option.
        field(json!({"type": "string", "enum": ["No answer", "Yes"]}), json!(["a", "b"])),
        // An order that names a field twice, or holds a non-string.
        field(json!({"type": "integer"}), json!(["a", "a"])),
        field(json!({"type": "integer"}), json!(["a", "b", 3])),
    ];
    // The same form in a sound order is asked.
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    assert!(asked(&t, &field(json!({"type": "integer"}), json!(["a", "b"]))).await.is_some());
    for line in forms {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        assert!(asked(&t, &line).await.is_none(), "{line}");
        assert_eq!(t.take_stdin_replies().await[0]["response"]["subtype"], "error");
    }
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
