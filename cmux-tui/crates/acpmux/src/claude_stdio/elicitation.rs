//! An MCP server's elicitation (`elicitation/create`), which Claude Code
//! forwards to its SDK host as a `control_request` with subtype
//! `elicitation`: `{mcp_server_name, message, mode, url, elicitation_id,
//! requested_schema, property_order, title, display_name, description}`,
//! answered `{action: accept | decline | cancel, content?}`.
//!
//! A form whose fields are all flat (a string, a number or integer, a
//! boolean, a single choice from `enum`/`oneOf`, or several from an array of
//! `enum`/`anyOf`) is asked as an agent question
//! (`toolCall._meta.acpmux.question`, `hub/questions.rs`), one item per
//! field, answered by question text like Claude Code's AskUserQuestion. Only
//! a person answers it: no policy, and no session above this one. Submit
//! accepts with the answers as the form's content, Skip declines, a stopped
//! turn cancels. URL mode and any other schema keep the error reply that
//! tells Claude Code acpmux does not support the request.

use super::*;
use serde_json::Map;

/// The most fields one form may ask; a longer one is declined as unsupported.
const MAX_FIELDS: usize = 8;
/// The option an optional field adds: choosing it leaves the field out.
const NO_ANSWER: &str = "No answer";

/// One pending elicitation: the form's fields, by item, until the answer.
pub(super) struct Form {
    fields: Vec<Field>,
}

struct Field {
    /// The property name in the form's content.
    key: String,
    /// The question text its answer is keyed by.
    prompt: String,
    kind: Kind,
    required: bool,
}

enum Kind {
    /// `(label, value)` per choice; several may be chosen when `multi`.
    Choice { choices: Vec<(String, Value)>, multi: bool },
    Bool,
    Text,
    Number { integer: bool },
}

impl Translator {
    /// `control_request` `elicitation` with id `rid`: a question for the hub,
    /// or, for a request acpmux cannot ask, the unsupported reply.
    pub(super) async fn elicit(&self, sid: &str, rid: &str, req: &Value) -> Vec<Message> {
        let Some((form, items)) = form(req) else {
            self.decline_control(rid, "elicitation").await;
            return Vec::new();
        };
        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
        let acp_id = Value::from(1_000_000 + n);
        self.control_out.lock().await.insert(rid.to_owned(), acp_id.clone());
        self.elicitations.lock().await.insert(rid.to_owned(), form);
        let server = server_name(req);
        let message = text(&req["message"]).unwrap_or_default();
        let call = json!({
            "toolCallId": format!("elicitation-{rid}"),
            "title": format!("{server}: {message}"),
            "kind": "other",
            "status": "pending",
            "rawInput": {"server": server, "message": message, "schema": req["requested_schema"]},
            "_meta": {
                "claude": {"elicitation": true, "server": server, "interactive": true},
                "acpmux": {"question": {"harness": "claude", "agent": server, "items": items}},
            },
        });
        vec![Message::request(
            acp_id,
            method::SESSION_REQUEST_PERMISSION,
            json!({
                "sessionId": sid,
                "toolCall": call,
                "options": [
                    {"optionId": "allow_once", "name": "Submit", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Decline", "kind": "reject_once"},
                ],
            }),
        )]
    }

    /// Answers control request `rid` of `subtype` with an error, so Claude
    /// Code does not wait on one acpmux does not support.
    pub(super) async fn decline_control(&self, rid: &str, subtype: &str) {
        tracing::debug!("claude control_request {subtype} declined");
        self.stdin_replies.lock().await.push(json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": rid,
                "error": format!("acpmux does not support control request {subtype}"),
            }
        }));
    }
}

/// The `control_response` line for elicitation `rid` from the hub's answer:
/// Submit accepts with the content, Skip (the reject option) declines, and a
/// cancel, an error or an unknown option cancels.
pub(super) fn reply(rid: &str, form: &Form, result: Option<&Value>, error: bool) -> Value {
    let outcome = result.and_then(|r| r.get("outcome")).cloned().unwrap_or(Value::Null);
    let selected = outcome.get("optionId").and_then(Value::as_str);
    let cancelled = error || outcome.get("outcome").and_then(Value::as_str) == Some("cancelled");
    let response = match selected {
        Some("allow_once") if !cancelled => {
            let answers = result
                .and_then(|r| r.pointer("/_meta/updatedInput/answers"))
                .cloned()
                .unwrap_or(Value::Null);
            json!({"action": "accept", "content": content(form, &answers)})
        }
        Some("reject_once") if !cancelled => json!({"action": "decline"}),
        _ => json!({"action": "cancel"}),
    };
    json!({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": response}})
}

/// The form's content from answers keyed by question text. A field left
/// unanswered, answered "No answer", or with a number that does not parse is
/// left out; the MCP server checks what it requires.
fn content(form: &Form, answers: &Value) -> Value {
    let mut out = Map::new();
    for field in &form.fields {
        let Some(answer) = answers.get(&field.prompt).and_then(Value::as_str).map(str::trim) else {
            continue;
        };
        if answer.is_empty() || (!field.required && answer == NO_ANSWER) {
            continue;
        }
        let value = match &field.kind {
            Kind::Choice { choices, multi: false } => {
                choices.iter().find(|(label, _)| label == answer).map(|(_, v)| v.clone())
            }
            Kind::Choice { choices, multi: true } => Some(Value::Array(chosen(choices, answer))),
            Kind::Bool => match answer {
                "Yes" => Some(json!(true)),
                "No" => Some(json!(false)),
                _ => None,
            },
            Kind::Text => Some(json!(answer)),
            Kind::Number { integer: true } => answer.parse::<i64>().ok().map(Value::from),
            Kind::Number { integer: false } => answer
                .parse::<f64>()
                .ok()
                .filter(|v| v.is_finite())
                .and_then(serde_json::Number::from_f64)
                .map(Value::Number),
        };
        if let Some(value) = value {
            out.insert(field.key.clone(), value);
        }
    }
    Value::Object(out)
}

/// The values of a multi-select answer: the chosen labels joined by ", ".
/// A label that itself holds ", " is matched whole, longest first.
fn chosen(choices: &[(String, Value)], answer: &str) -> Vec<Value> {
    let parts: Vec<&str> = answer.split(", ").collect();
    let mut values = Vec::new();
    let mut i = 0;
    while i < parts.len() {
        let hit = (i + 1..=parts.len()).rev().find_map(|j| {
            let label = parts[i..j].join(", ");
            choices.iter().find(|(l, _)| *l == label).map(|(_, v)| (j, v.clone()))
        });
        match hit {
            Some((j, value)) => {
                values.push(value);
                i = j;
            }
            None => i += 1,
        }
    }
    values
}

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// The asking server as the person knows it: its display name, else its name.
fn server_name(req: &Value) -> String {
    text(&req["display_name"])
        .or_else(|| text(&req["mcp_server_name"]))
        .unwrap_or_else(|| "MCP server".to_owned())
}

/// The form and its question items, when every field can be asked.
fn form(req: &Value) -> Option<(Form, Vec<Value>)> {
    if req["mode"].as_str().is_some_and(|m| m != "form") {
        return None;
    }
    let schema = &req["requested_schema"];
    let properties = schema["properties"].as_object()?;
    let required: Vec<&str> =
        schema["required"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    // Claude Code sends the server's own order; serde_json's map is sorted.
    let order: Vec<String> = match req["property_order"].as_array() {
        Some(keys) => keys.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
        None => properties.keys().cloned().collect(),
    };
    if order.len() != properties.len()
        || order.len() > MAX_FIELDS
        || order.iter().any(|k| !properties.contains_key(k))
    {
        return None;
    }
    let message = text(&req["message"]);
    let single = order.len() == 1;
    let mut fields = Vec::new();
    let mut items = Vec::new();
    for (index, key) in order.iter().enumerate() {
        let property = &properties[key];
        let kind = kind(property)?;
        let label = text(&property["title"]).unwrap_or_else(|| key.clone());
        let own = text(&property["description"]).unwrap_or_else(|| label.clone());
        let mut prompt = match (&message, single, index) {
            (Some(m), true, _) => m.clone(),
            (Some(m), false, 0) => format!("{m} — {own}"),
            _ => own,
        };
        if fields.iter().any(|f: &Field| f.prompt == prompt) {
            prompt = format!("{prompt} ({key})");
        }
        let is_required = required.contains(&key.as_str());
        let mut options: Vec<Value> = match &kind {
            Kind::Choice { choices, .. } => {
                choices.iter().map(|(label, _)| json!({"id": label, "label": label})).collect()
            }
            Kind::Bool => vec![json!({"id": "Yes", "label": "Yes"}), json!({"id": "No", "label": "No"})],
            Kind::Text | Kind::Number { .. } => Vec::new(),
        };
        if !is_required {
            options.push(json!({"id": NO_ANSWER, "label": NO_ANSWER}));
        }
        let allows_other = matches!(kind, Kind::Text | Kind::Number { .. });
        let multi = matches!(kind, Kind::Choice { multi: true, .. });
        let header = if single { server_name(req) } else { label };
        items.push(json!({
            "id": format!("q{index}"), "header": header, "prompt": prompt, "options": options,
            "multiSelect": multi, "allowsOther": allows_other,
        }));
        fields.push(Field { key: key.clone(), prompt, kind, required: is_required });
    }
    if fields.is_empty() {
        // A form with nothing to fill: a confirmation, accepted empty.
        let prompt = message?;
        items.push(json!({
            "id": "q0", "header": server_name(req), "prompt": prompt,
            "options": [{"id": "Accept", "label": "Accept"}], "multiSelect": false, "allowsOther": false,
        }));
    }
    Some((Form { fields }, items))
}

/// What a property asks for, when it is one of the MCP flat field shapes.
fn kind(property: &Value) -> Option<Kind> {
    let titled = |list: &Value| -> Option<Vec<(String, Value)>> {
        let list = list.as_array()?;
        list.iter()
            .map(|c| {
                let value = c.get("const")?.as_str()?;
                let label = text(&c["title"]).unwrap_or_else(|| value.to_owned());
                Some((label, json!(value)))
            })
            .collect()
    };
    let listed = |list: &Value, names: &Value| -> Option<Vec<(String, Value)>> {
        let list = list.as_array()?;
        list.iter()
            .enumerate()
            .map(|(i, v)| {
                let value = v.as_str()?;
                let label = text(&names[i]).unwrap_or_else(|| value.to_owned());
                Some((label, json!(value)))
            })
            .collect()
    };
    let distinct = |choices: Vec<(String, Value)>| {
        let mut seen = std::collections::HashSet::new();
        (!choices.is_empty() && choices.iter().all(|(label, _)| seen.insert(label.clone())))
            .then_some(choices)
    };
    match property["type"].as_str()? {
        "string" if property.get("oneOf").is_some() => {
            Some(Kind::Choice { choices: distinct(titled(&property["oneOf"])?)?, multi: false })
        }
        "string" if property.get("enum").is_some() => Some(Kind::Choice {
            choices: distinct(listed(&property["enum"], &property["enumNames"])?)?,
            multi: false,
        }),
        "string" => Some(Kind::Text),
        "array" => {
            let items = &property["items"];
            let choices = match (items.get("anyOf"), items.get("enum")) {
                (Some(any), _) => titled(any)?,
                (None, Some(list)) => listed(list, &Value::Null)?,
                (None, None) => return None,
            };
            Some(Kind::Choice { choices: distinct(choices)?, multi: true })
        }
        "boolean" => Some(Kind::Bool),
        "number" => Some(Kind::Number { integer: false }),
        "integer" => Some(Kind::Number { integer: true }),
        _ => None,
    }
}
