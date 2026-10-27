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
//! turn cancels, and so does an answer acpmux cannot carry as the person gave
//! it (a choice not offered, a number that does not parse): the server never
//! gets content the person did not give. URL mode and any other schema keep
//! the error reply that tells Claude Code acpmux does not support the request;
//! so does a form with an optional string field, whose typed "No answer" the
//! card's one-string answer could not tell from the "No answer" option.
//! A form Claude Code withdraws (`control_cancel_request`) is forgotten, so a
//! late answer sends it nothing.

use super::*;
use serde_json::Map;

/// The most fields one form may ask; a longer one is declined as unsupported.
const MAX_FIELDS: usize = 8;
/// The option an optional field adds: choosing it leaves the field out.
const NO_ANSWER: &str = "No answer";
/// How a client joins a multi-select answer's labels (`webviews` model.ts,
/// `question_answer.rs`): a multi-select label holds no comma at all.
const JOIN: &str = ", ";

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
    Choice {
        choices: Vec<(String, Value)>,
        multi: bool,
    },
    Bool,
    Text,
    Number {
        integer: bool,
    },
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
        {
            // Request map first, as everywhere (`forget_elicitation`).
            let mut out = self.control_out.lock().await;
            out.insert(rid.to_owned(), acp_id.clone());
            self.elicitations.lock().await.insert(rid.to_owned(), form);
        }
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

    /// Claude Code withdrew its elicitation `rid` (`control_cancel_request`:
    /// the turn was interrupted, or the tool call that asked ended), so it
    /// reads no answer to it any more. The form is forgotten: a late answer to
    /// its card sends Claude Code nothing (`outbound.rs` finds no request).
    /// The card itself stays until it is answered or the turn is stopped;
    /// taking it back from the hub is a follow-up. Other requests are untouched.
    /// Both maps are held, the request map first, as the answer's path holds
    /// them (`outbound.rs`), so only one of the two takes the form.
    pub(super) async fn forget_elicitation(&self, rid: &str) {
        let mut out = self.control_out.lock().await;
        if self.elicitations.lock().await.remove(rid).is_some() {
            out.remove(rid);
        }
    }
}

/// The `control_response` line for elicitation `rid` from the hub's answer:
/// Submit accepts with the content, Skip (the reject option) declines, and a
/// cancel, an error, an unknown option or answers that are not the form's
/// cancel.
pub(super) fn reply(rid: &str, form: &Form, result: Option<&Value>, error: bool) -> Value {
    let outcome = result.and_then(|r| r.get("outcome")).cloned().unwrap_or(Value::Null);
    let selected = outcome.get("optionId").and_then(Value::as_str);
    let cancelled = error || outcome.get("outcome").and_then(Value::as_str) == Some("cancelled");
    let answers = result.and_then(|r| r.pointer("/_meta/updatedInput/answers"));
    let response = match selected {
        Some("allow_once") if !cancelled => match answers.and_then(|a| content(form, a)) {
            Some(content) => json!({"action": "accept", "content": content}),
            None => json!({"action": "cancel"}),
        },
        Some("reject_once") if !cancelled => json!({"action": "decline"}),
        _ => json!({"action": "cancel"}),
    };
    json!({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": response}})
}

/// The form's content from answers keyed by question text, or None when any
/// answer is not one the form offers: a required field left empty, a choice
/// that is not among its options, a yes/no that is neither, or a number that
/// does not parse. An optional field answered "No answer" is left out.
fn content(form: &Form, answers: &Value) -> Option<Value> {
    let mut out = Map::new();
    for field in &form.fields {
        let typed = answers.get(&field.prompt).and_then(Value::as_str);
        let answer = match typed.map(str::trim) {
            Some(a) if !a.is_empty() && (field.required || a != NO_ANSWER) => a,
            _ if field.required => return None,
            _ => continue,
        };
        let value = match &field.kind {
            Kind::Choice { choices, multi: false } => {
                choices.iter().find(|(label, _)| label == answer).map(|(_, v)| v.clone())
            }
            Kind::Choice { choices, multi: true } => {
                chosen(choices, answer, !field.required).map(Value::Array)
            }
            Kind::Bool => match answer {
                "Yes" => Some(json!(true)),
                "No" => Some(json!(false)),
                _ => None,
            },
            // Typed text goes as the hub gave it, spaces and all.
            Kind::Text => typed.map(|t| json!(t)),
            Kind::Number { integer: true } => answer.parse::<i64>().ok().map(Value::from),
            Kind::Number { integer: false } => exact_number(answer),
        };
        out.insert(field.key.clone(), value?);
    }
    Some(Value::Object(out))
}

/// The values of a multi-select answer, its labels joined by [`JOIN`] (which
/// no label holds), or None when one is not offered or is chosen twice. An
/// `optional` field's "No answer" beside real choices adds nothing.
fn chosen(choices: &[(String, Value)], answer: &str, optional: bool) -> Option<Vec<Value>> {
    let mut seen = std::collections::HashSet::new();
    answer
        .split(JOIN)
        .filter(|part| !(optional && part.trim() == NO_ANSWER))
        .map(|part| {
            let (label, value) = choices.iter().find(|(l, _)| l == part.trim())?;
            seen.insert(label).then(|| value.clone())
        })
        .collect()
}

/// A typed number as JSON, only when it is carried exactly: an integer as
/// itself, a plain decimal (no exponent) only when the nearest double reads
/// back as the same decimal. One that would be rounded (9007199254740993,
/// 0.10000000000000000001) is refused, never sent as another number.
fn exact_number(answer: &str) -> Option<Value> {
    if let Ok(integer) = answer.parse::<i64>() {
        return Some(Value::from(integer));
    }
    let digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    let unsigned = answer.strip_prefix('-').unwrap_or(answer);
    let (whole, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if whole.is_empty() || !digits(whole) || !digits(fraction) {
        return None;
    }
    let value = answer.parse::<f64>().ok().filter(|v| v.is_finite())?;
    // Rust prints a double as the shortest plain decimal that reads back as it.
    (decimal(answer) == decimal(&value.to_string()))
        .then(|| serde_json::Number::from_f64(value).map(Value::Number))
        .flatten()
}

/// A plain decimal written one way: no leading zeros, no trailing fraction
/// zeros, no sign on zero.
fn decimal(text: &str) -> String {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (whole, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    let whole = match whole.trim_start_matches('0') {
        "" => "0",
        w => w,
    };
    let fraction = fraction.trim_end_matches('0');
    let body = if fraction.is_empty() { whole.to_owned() } else { format!("{whole}.{fraction}") };
    if negative && body != "0" { format!("-{body}") } else { body }
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
    // It names every property once, or the form is not asked.
    let order: Vec<String> = match req["property_order"].as_array() {
        Some(keys) => keys.iter().map(|k| k.as_str().map(str::to_owned)).collect::<Option<_>>()?,
        None => properties.keys().cloned().collect(),
    };
    let unique: std::collections::HashSet<&String> = order.iter().collect();
    if order.len() != properties.len()
        || unique.len() != order.len()
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
        // Answers are keyed by prompt, so each must be distinct: a repeat gets
        // its key, and a form where even that repeats is not asked.
        let taken = |prompt: &str, fields: &[Field]| fields.iter().any(|f| f.prompt == prompt);
        if taken(&prompt, &fields) {
            prompt = format!("{prompt} ({key})");
            if taken(&prompt, &fields) {
                return None;
            }
        }
        let is_required = required.contains(&key.as_str());
        // An optional string field is not asked: the card answers it with one
        // string, the typed text or the "No answer" option's label alike, so
        // typed "No answer" could not be told from leaving the field out. (A
        // number field may offer it: typed "No answer" is no number anyway.)
        if matches!(kind, Kind::Text) && !is_required {
            return None;
        }
        // "No answer" leaves an optional field out, so it is no choice of one.
        if let Kind::Choice { choices, .. } = &kind
            && !is_required
            && choices.iter().any(|(label, _)| label == NO_ANSWER)
        {
            return None;
        }
        let mut options: Vec<Value> = match &kind {
            Kind::Choice { choices, .. } => {
                choices.iter().map(|(label, _)| json!({"id": label, "label": label})).collect()
            }
            Kind::Bool => {
                vec![json!({"id": "Yes", "label": "Yes"}), json!({"id": "No", "label": "No"})]
            }
            Kind::Text | Kind::Number { .. } => Vec::new(),
        };
        if !is_required {
            options.push(json!({"id": NO_ANSWER, "label": NO_ANSWER}));
        }
        let allows_other = matches!(kind, Kind::Text | Kind::Number { .. });
        let multi = matches!(kind, Kind::Choice { multi: true, .. });
        let header = if single { server_name(req) } else { label };
        let mut item = json!({
            "id": format!("q{index}"), "header": header, "prompt": prompt, "options": options,
            "multiSelect": multi, "allowsOther": allows_other,
        });
        // A number is typed, so a client sends its digits to the text, not
        // to option shortcuts (`tui/answering.rs`).
        if matches!(kind, Kind::Number { .. }) {
            item["input"] = json!("number");
        }
        items.push(item);
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
/// Its choices have distinct, non-empty labels; a multi-select label holds
/// no comma, so an answer's labels split back exactly, whether joined by
/// [`JOIN`] or split on commas (`question_answer.rs`, `acpmux answer`).
fn kind(property: &Value) -> Option<Kind> {
    let titled = |list: &Value| -> Option<Vec<(String, Value)>> {
        let list = list.as_array()?;
        list.iter()
            .map(|c| {
                let value = c.get("const")?.as_str()?;
                let label = text(&c["title"]).or_else(|| text(&c["const"]))?;
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
                let label = text(&names[i]).or_else(|| text(v))?;
                Some((label, json!(value)))
            })
            .collect()
    };
    let distinct = |choices: Vec<(String, Value)>, multi: bool| {
        let mut seen = std::collections::HashSet::new();
        let ok = !choices.is_empty()
            && choices
                .iter()
                .all(|(label, _)| seen.insert(label.clone()) && !(multi && label.contains(',')));
        ok.then_some(Kind::Choice { choices, multi })
    };
    match property["type"].as_str()? {
        "string" if property.get("oneOf").is_some() => distinct(titled(&property["oneOf"])?, false),
        "string" if property.get("enum").is_some() => {
            distinct(listed(&property["enum"], &property["enumNames"])?, false)
        }
        "string" => Some(Kind::Text),
        "array" => {
            let items = &property["items"];
            let choices = match (items.get("anyOf"), items.get("enum")) {
                (Some(any), _) => titled(any)?,
                (None, Some(list)) => listed(list, &items["enumNames"])?,
                (None, None) => return None,
            };
            distinct(choices, true)
        }
        "boolean" => Some(Kind::Bool),
        "number" => Some(Kind::Number { integer: false }),
        "integer" => Some(Kind::Number { integer: true }),
        _ => None,
    }
}
