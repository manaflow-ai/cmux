//! Builds the phone's contract from the two protocol IRs it rides on:
//! the cmux-tui daemon's SDK schema (`cmux-tui/spec/sdk-schema.json`) and acpmux's
//! JSON-Schema IR (`cmux-tui/crates/acpmux/spec/acpmux-protocol.json`), cut to the
//! methods a phone may call, plus the link services hostd serves.
//!
//! Output shape (the acpmux IR shape, so `cmux-api-compat`'s `json_schema` checks it
//! by the same break rules as the daemon and acpmux):
//! `{contract, version, methods: [{name, service, kind, since?, capability?, params, result?, events?}], types}`.
//! Type names carry their protocol (`daemon.Id`, `acpmux.SessionPromptParams`).
//!
//! Request roots stay closed (`additionalProperties: false`, as both IRs declare
//! them): an unknown field is an error the phone sees, not a silent no-op. Results
//! and events are read open: a reader ignores a field or event it does not know.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value, json};

/// One link service hostd serves (`services.rs`), and the `version` capability that says so.
#[derive(Clone, Copy, Debug)]
pub struct LinkService {
    pub name: &'static str,
    /// `None`: served by every hostd that has the `api` service (no capability names it).
    pub capability: Option<&'static str>,
    pub meaning: &'static str,
}

/// What the contract is cut from.
pub struct Inputs<'a> {
    pub sdk: &'a Value,
    pub acpmux: &'a Value,
    /// Daemon commands a phone may send (hostd `policy::ALLOWED_COMMANDS`).
    pub daemon_commands: &'a BTreeSet<&'a str>,
    /// acpmux methods (requests, notifications both ways) the phone uses.
    pub acpmux_methods: &'a BTreeSet<&'a str>,
    pub services: &'a [LinkService],
}

/// The contract document, or what in the inputs has no schema.
pub fn build(inputs: &Inputs<'_>) -> Result<Value, Vec<String>> {
    let mut problems = Vec::new();
    let mut methods = Vec::new();
    let mut types = BTreeMap::new();

    for service in inputs.services {
        let mut method = json!({
            "name": format!("link/{}", service.name),
            "service": service.name,
            "kind": "request",
            "params": true,
            "description": service.meaning,
        });
        if let Some(capability) = service.capability {
            method["capability"] = json!(capability);
        }
        methods.push(method);
    }

    let commands = inputs.sdk.get("commands").and_then(Value::as_object);
    let sdk_types = inputs.sdk.get("types").and_then(Value::as_object);
    let mut daemon_refs = BTreeSet::new();
    for name in inputs.daemon_commands {
        let Some(command) = commands.and_then(|c| c.get(*name)) else {
            problems.push(format!(
                "daemon command {name} is allowed for a phone (hostd policy.rs ALLOWED_COMMANDS) but has no schema in cmux-tui/spec/sdk-schema.json"
            ));
            continue;
        };
        let params = sdk_to_schema(&command["request"], &mut daemon_refs);
        let result = sdk_to_schema(&command["result"], &mut daemon_refs);
        let mut method = json!({
            "name": format!("daemon/{name}"),
            "service": "daemon",
            "kind": "request",
            "params": params,
            "result": result,
        });
        annotate(&mut method, command);
        if let Some(stream) = command.get("stream").filter(|s| !s.is_null())
            && let Some(events) = stream.get("event_names")
        {
            method["events"] = events.clone();
        }
        methods.push(method);
    }
    for (name, event) in inputs.sdk.get("events").and_then(Value::as_object).into_iter().flatten() {
        if inputs.daemon_commands.contains(name.as_str()) {
            problems.push(format!("daemon event {name} has a command's name"));
        }
        let payload = sdk_to_schema(&event["payload"], &mut daemon_refs);
        let mut method = json!({
            "name": format!("daemon/{name}"),
            "service": "daemon",
            "kind": "notification",
            "params": payload,
        });
        annotate(&mut method, event);
        methods.push(method);
    }
    let mut seen = BTreeSet::new();
    while let Some(name) = daemon_refs.iter().find(|n| !seen.contains(*n)).cloned() {
        seen.insert(name.clone());
        match sdk_types.and_then(|t| t.get(&name)) {
            Some(ty) => {
                let schema = sdk_to_schema(ty, &mut daemon_refs);
                types.insert(format!("daemon.{name}"), schema);
            }
            None => problems.push(format!("daemon type {name} is referenced but not defined")),
        }
    }

    let acp_methods: BTreeMap<&str, &Value> = inputs
        .acpmux
        .get("methods")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| Some((m.get("name")?.as_str()?, m)))
        .collect();
    let acp_types = inputs.acpmux.get("types").and_then(Value::as_object);
    let mut acp_refs = BTreeSet::new();
    for name in inputs.acpmux_methods {
        let Some(method) = acp_methods.get(name) else {
            problems.push(format!(
                "acpmux method {name} is sent or read by the phone but is not in acpmux-protocol.json"
            ));
            continue;
        };
        let mut out = Map::new();
        out.insert("name".into(), json!(format!("acpmux/{name}")));
        out.insert("service".into(), json!("acpmux"));
        out.insert("kind".into(), method.get("kind").cloned().unwrap_or(json!("request")));
        out.insert(
            "params".into(),
            prefix_refs(method.get("params").unwrap_or(&Value::Bool(true)), &mut acp_refs),
        );
        if let Some(result) = method.get("result").filter(|r| !r.is_null()) {
            out.insert("result".into(), prefix_refs(result, &mut acp_refs));
        }
        methods.push(Value::Object(out));
    }
    let mut seen = BTreeSet::new();
    while let Some(name) = acp_refs.iter().find(|n| !seen.contains(*n)).cloned() {
        seen.insert(name.clone());
        match acp_types.and_then(|t| t.get(&name)) {
            Some(ty) => {
                let schema = prefix_refs(ty, &mut acp_refs);
                types.insert(format!("acpmux.{name}"), schema);
            }
            None => problems.push(format!("acpmux type {name} is referenced but not defined")),
        }
    }

    let mut names = BTreeSet::new();
    for method in &methods {
        let key = (
            method["name"].as_str().unwrap_or("").to_owned(),
            method["kind"].as_str().unwrap_or("").to_owned(),
        );
        if !names.insert(key.clone()) {
            problems.push(format!("{} ({}) is listed twice", key.0, key.1));
        }
    }
    if !problems.is_empty() {
        return Err(problems);
    }
    methods.sort_by(|a, b| {
        (a["name"].as_str(), a["kind"].as_str()).cmp(&(b["name"].as_str(), b["kind"].as_str()))
    });
    Ok(json!({
        "contract": crate::CONTRACT,
        "version": crate::CONTRACT_VERSION,
        "generated": "by `CMUX_UPDATE_PHONE_API=1 cargo test -p cmux-mobile-host --test phone_api_contract` from cmux-tui/spec/sdk-schema.json, acpmux-protocol.json and hostd's allow lists; do not edit",
        "methods": methods,
        "types": types,
    }))
}

/// Copies `since`, `capability` and the per-field capabilities of a daemon command or event.
fn annotate(method: &mut Value, ir: &Value) {
    if let Some(since) = ir.get("since").filter(|v| !v.is_null()) {
        method["since"] = since.clone();
    }
    if let Some(capability) = ir.get("capability").filter(|v| !v.is_null()) {
        method["capability"] = capability.clone();
    }
}

/// One SDK IR type as JSON Schema; every `ref` it names lands in `refs`.
pub fn sdk_to_schema(ir: &Value, refs: &mut BTreeSet<String>) -> Value {
    let Some(kind) = ir.get("kind").and_then(Value::as_str) else { return Value::Bool(true) };
    match kind {
        "scalar" => scalar(ir.get("name").and_then(Value::as_str).unwrap_or("string")),
        "ref" => {
            let name = ir.get("name").and_then(Value::as_str).unwrap_or_default();
            refs.insert(name.to_owned());
            json!({ "$ref": format!("#/types/daemon.{name}") })
        }
        "alias" => sdk_to_schema(&ir["target"], refs),
        "literal" => json!({ "const": ir["value"] }),
        "enum" => {
            let mut schema = json!({ "enum": ir["values"] });
            if let Some(fallback) = ir.get("fallback").filter(|f| !f.is_null()) {
                schema["x-fallback"] = fallback.clone();
            }
            schema
        }
        "array" => {
            let mut schema = json!({ "type": "array", "items": sdk_to_schema(&ir["items"], refs) });
            if let Some(n) = ir.get("min_items").filter(|n| !n.is_null()) {
                schema["minItems"] = n.clone();
            }
            if let Some(n) = ir.get("max_items").filter(|n| !n.is_null()) {
                schema["maxItems"] = n.clone();
            }
            schema
        }
        "map" => json!({ "type": "object", "additionalProperties": sdk_to_schema(&ir["values"], refs) }),
        "object" => object(ir, refs),
        "tagged_union" => {
            let variants: Vec<Value> = ir
                .get("variants")
                .and_then(Value::as_object)
                .into_iter()
                .flatten()
                .map(|(_, v)| sdk_to_schema(v, refs))
                .collect();
            json!({ "oneOf": variants, "x-tag": ir["tag"] })
        }
        "untagged_union" => {
            let variants: Vec<Value> = ir
                .get("variants")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|v| sdk_to_schema(v, refs))
                .collect();
            json!({ "anyOf": variants })
        }
        // `opaque_json` and anything newer: any JSON.
        _ => Value::Bool(true),
    }
}

fn scalar(name: &str) -> Value {
    match name {
        "string" => json!({ "type": "string" }),
        "boolean" => json!({ "type": "boolean" }),
        n if n.starts_with("uint") => json!({ "type": "integer", "format": n, "minimum": 0 }),
        n if n.starts_with("int") => json!({ "type": "integer", "format": n }),
        n if n.starts_with("float") => json!({ "type": "number", "format": n }),
        n => json!({ "type": "string", "format": n }),
    }
}

fn object(ir: &Value, refs: &mut BTreeSet<String>) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for (name, field) in ir.get("fields").and_then(Value::as_object).into_iter().flatten() {
        let mut schema = sdk_to_schema(&field["type"], refs);
        if field.get("nullable") == Some(&Value::Bool(true)) {
            schema = json!({ "anyOf": [schema, { "type": "null" }] });
        }
        if let Value::Object(map) = &mut schema {
            for (from, to) in [("since", "x-since"), ("capability", "x-capability"), ("default", "default")] {
                if let Some(value) = field.get(from).filter(|v| !v.is_null()) {
                    map.insert(to.into(), value.clone());
                }
            }
            let words: Vec<&str> = field
                .get("constraints")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            if !words.is_empty() {
                map.insert("description".into(), json!(words.join(" ")));
            }
        }
        if field.get("presence").and_then(Value::as_str) == Some("required") {
            required.push(json!(name));
        }
        properties.insert(name.clone(), schema);
    }
    let mut schema = json!({ "type": "object", "properties": properties });
    if !required.is_empty() {
        schema["required"] = Value::Array(required);
    }
    if ir.get("additional_properties") == Some(&Value::Bool(false)) {
        schema["additionalProperties"] = Value::Bool(false);
    }
    schema
}

/// An acpmux JSON Schema with its `#/types/X` refs renamed `#/types/acpmux.X`.
fn prefix_refs(schema: &Value, refs: &mut BTreeSet<String>) -> Value {
    match schema {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| {
                    if k == "$ref"
                        && let Some(name) = v.as_str().and_then(|r| r.strip_prefix("#/types/"))
                    {
                        refs.insert(name.to_owned());
                        return (k.clone(), json!(format!("#/types/acpmux.{name}")));
                    }
                    (k.clone(), prefix_refs(v, refs))
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(|v| prefix_refs(v, refs)).collect()),
        other => other.clone(),
    }
}
