//! The phone's app-level API on a Mac, as one method list with JSON Schemas.
//!
//! Leo: "well clearly we need to be able to support the multiple versions as it goes".
//! A phone and a Mac build differ for days at a time (TestFlight vs NIGHTLY). This crate is
//! what lets them: the Mac serves the list of every method it answers (`api list`), each with
//! its request and response schema (`api describe`), and an llms.txt. The phone asks what the
//! Mac can do ([`Discovery`]) instead of comparing version numbers.
//!
//! Rules (cmux-next-ios/contract/README.md, "App-level API"):
//! - Requests are strict: a field the schema does not name is an error ([`Contract::check_request`]).
//! - Readers are tolerant: a response field or event a reader does not know is skipped.
//! - A change to a method's schema needs a compat rule in `phone-api.compat.json`; the
//!   `phone_api_contract` test in cmux-mobile-host fails otherwise.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

use serde_json::{Value, json};

pub mod lower;

pub const CONTRACT: &str = "cmux-mobile-api";
pub const CONTRACT_VERSION: u64 = 1;

/// The committed contract (`phone-api.json`), built from the protocol IRs by [`lower::build`].
pub const PHONE_API_JSON: &str = include_str!("../phone-api.json");

/// Fields every daemon line carries that are not part of a command's request
/// (hostd `policy::ENVELOPE_FIELDS`).
pub const ENVELOPE_FIELDS: &[&str] = &["id", "cmd", "_meta"];

static CONTRACT_DOC: LazyLock<Contract> =
    LazyLock::new(|| Contract::from_json(PHONE_API_JSON).expect("phone-api.json parses"));

/// The embedded contract.
pub fn contract() -> &'static Contract {
    &CONTRACT_DOC
}

pub struct Contract {
    doc: Value,
    methods: BTreeMap<(String, String), Value>,
    digest: String,
}

impl Contract {
    pub fn from_json(text: &str) -> Result<Self, String> {
        let doc: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        Ok(Self::from_value(doc))
    }

    pub fn from_value(doc: Value) -> Self {
        let methods = doc
            .get("methods")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| {
                let name = m.get("name")?.as_str()?.to_owned();
                let kind = m.get("kind")?.as_str()?.to_owned();
                Some(((name, kind), m.clone()))
            })
            .collect();
        let canonical = serde_json::to_string(&doc).unwrap_or_default();
        Self { doc, methods, digest: format!("fnv1a64:{:016x}", fnv1a64(canonical.as_bytes())) }
    }

    pub fn document(&self) -> &Value {
        &self.doc
    }

    /// Stable across runs and machines: two Macs with the same digest answer the same methods
    /// with the same schemas, so a phone may keep its cached `describe` results.
    pub fn digest(&self) -> &str {
        &self.digest
    }

    /// The method a phone sends (`kind` request or client_notification) or reads (notification).
    pub fn method(&self, name: &str) -> Option<&Value> {
        ["request", "client_notification", "notification"]
            .iter()
            .find_map(|kind| self.methods.get(&(name.to_owned(), (*kind).to_owned())))
    }

    /// `api list`: every method with its kind, since and capability, no schemas.
    /// `served(method)` drops what this hostd does not serve (a link service whose
    /// capability it does not advertise).
    pub fn list(&self, served: impl Fn(&Value) -> bool) -> Value {
        let methods: Vec<Value> = self
            .methods
            .values()
            .filter(|m| served(m))
            .map(|m| {
                let mut out = json!({ "name": m["name"], "kind": m["kind"] });
                for key in ["since", "capability"] {
                    if let Some(v) = m.get(key) {
                        out[key] = v.clone();
                    }
                }
                out
            })
            .collect();
        json!({
            "contract": CONTRACT,
            "version": CONTRACT_VERSION,
            "digest": self.digest,
            "methods": methods,
        })
    }

    /// `api describe`: one method with every type its schemas reach.
    pub fn describe(&self, name: &str) -> Option<Value> {
        let kinds: Vec<&Value> =
            self.methods.iter().filter(|((n, _), _)| n == name).map(|(_, m)| m).collect();
        if kinds.is_empty() {
            return None;
        }
        let mut pending = BTreeSet::new();
        for method in &kinds {
            collect_refs(method, &mut pending);
        }
        let all_types = self.doc.get("types").and_then(Value::as_object);
        let mut types = serde_json::Map::new();
        while let Some(ty) = pending.pop_first() {
            if types.contains_key(&ty) {
                continue;
            }
            if let Some(schema) = all_types.and_then(|t| t.get(&ty)) {
                collect_refs(schema, &mut pending);
                types.insert(ty, schema.clone());
            }
        }
        Some(json!({
            "contract": CONTRACT,
            "version": CONTRACT_VERSION,
            "digest": self.digest,
            "methods": kinds,
            "types": types,
        }))
    }

    /// `api llms`: the list as plain text an agent can read.
    pub fn llms_txt(&self, served: impl Fn(&Value) -> bool) -> String {
        let mut out = String::from(
            "# cmux phone API\n\n\
             > Every method a phone may call on this Mac after the link connects.\n\
             > Requests are strict (an unknown field is an error); readers skip unknown\n\
             > response fields and events. Ask `api describe <name>` for a method's schemas.\n\n",
        );
        let mut service = String::new();
        for method in self.methods.values().filter(|m| served(m)) {
            let group = method["name"].as_str().and_then(|n| n.split_once('/')).map_or("", |(g, _)| g);
            if group != service {
                service = group.to_owned();
                out.push_str(&format!("\n## {service}\n\n"));
            }
            out.push_str(&format!(
                "- {} ({})",
                method["name"].as_str().unwrap_or(""),
                method["kind"].as_str().unwrap_or("")
            ));
            if let Some(c) = method.get("capability").and_then(Value::as_str) {
                out.push_str(&format!(" capability {c}"));
            }
            if let Some(d) = method.get("description").and_then(Value::as_str) {
                out.push_str(&format!(": {d}"));
            }
            out.push('\n');
        }
        out
    }

    /// The fields of `params` that `name`'s request schema does not allow, as JSON pointers.
    /// Empty when the request is well formed, the method is not listed, or its params are
    /// untyped. Envelope fields are skipped at the root.
    pub fn check_request(&self, name: &str, params: &Value) -> Vec<String> {
        let Some(method) = self.method(name) else { return Vec::new() };
        let Some(schema) = method.get("params") else { return Vec::new() };
        let mut problems = Vec::new();
        self.check(schema, params, "", true, 0, &mut problems);
        problems
    }

    /// [`Self::check_request`] on a line's members, without building a `Value` around them.
    pub fn check_request_fields(&self, name: &str, fields: &serde_json::Map<String, Value>) -> Vec<String> {
        let Some(schema) = self.method(name).and_then(|m| m.get("params")) else { return Vec::new() };
        let Some(map) = self.resolve(schema).as_object() else { return Vec::new() };
        let mut problems = Vec::new();
        self.check_fields(map, fields, "", true, 0, &mut problems);
        problems
    }

    fn resolve<'a>(&'a self, schema: &'a Value) -> &'a Value {
        let mut schema = schema;
        for _ in 0..16 {
            match schema.get("$ref").and_then(Value::as_str).and_then(|r| r.strip_prefix("#/types/")) {
                Some(name) => match self.doc.get("types").and_then(|t| t.get(name)) {
                    Some(next) => schema = next,
                    None => return &Value::Bool(true),
                },
                None => return schema,
            }
        }
        schema
    }

    /// The strict half of a JSON Schema check: unknown fields, missing required fields,
    /// wrong JSON types, values outside an enum or const. Formats and bounds are the
    /// daemon's own check.
    fn check(
        &self,
        schema: &Value,
        value: &Value,
        at: &str,
        root: bool,
        depth: usize,
        out: &mut Vec<String>,
    ) {
        if depth > 32 {
            return;
        }
        let schema = self.resolve(schema);
        let Some(map) = schema.as_object() else { return };
        if let Some(variants) = map.get("anyOf").or_else(|| map.get("oneOf")).and_then(Value::as_array) {
            let mut best: Option<Vec<String>> = None;
            for variant in variants {
                let mut problems = Vec::new();
                self.check(variant, value, at, root, depth + 1, &mut problems);
                if problems.is_empty() {
                    return;
                }
                if best.as_ref().is_none_or(|b| problems.len() < b.len()) {
                    best = Some(problems);
                }
            }
            if map.get("type").is_none() && map.get("properties").is_none() {
                out.extend(best.unwrap_or_default());
                return;
            }
        }
        if let Some(c) = map.get("const")
            && c != value
        {
            out.push(format!("{at}: expected {c}"));
            return;
        }
        if let Some(values) = map.get("enum").and_then(Value::as_array)
            && !values.contains(value)
            && map.get("x-fallback").is_none()
        {
            out.push(format!("{at}: not one of {}", Value::Array(values.clone())));
            return;
        }
        if let Some(ty) = map.get("type").and_then(Value::as_str) {
            let ok = match ty {
                "object" => value.is_object(),
                "array" => value.is_array(),
                "string" => value.is_string(),
                "boolean" => value.is_boolean(),
                "integer" => value.is_i64() || value.is_u64(),
                "number" => value.is_number(),
                "null" => value.is_null(),
                _ => true,
            };
            if !ok {
                out.push(format!("{at}: expected {ty}"));
                return;
            }
        }
        if let Some(fields) = value.as_object() {
            self.check_fields(map, fields, at, root, depth, out);
        }
        if let (Some(items), Some(values)) = (map.get("items"), value.as_array()) {
            for (i, item) in values.iter().enumerate() {
                self.check(items, item, &format!("{at}/{i}"), false, depth + 1, out);
            }
        }
    }

    fn check_fields(
        &self,
        map: &serde_json::Map<String, Value>,
        fields: &serde_json::Map<String, Value>,
        at: &str,
        root: bool,
        depth: usize,
        out: &mut Vec<String>,
    ) {
        {
            let properties = map.get("properties").and_then(Value::as_object);
            for required in
                map.get("required").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str)
            {
                if !fields.contains_key(required) {
                    out.push(format!("{at}/{required}: required"));
                }
            }
            for (key, field) in fields {
                if root && ENVELOPE_FIELDS.contains(&key.as_str()) {
                    continue;
                }
                let path = format!("{at}/{key}");
                match properties.and_then(|p| p.get(key)) {
                    Some(sub) => self.check(sub, field, &path, false, depth + 1, out),
                    None => match map.get("additionalProperties") {
                        Some(Value::Bool(false)) if properties.is_some() || map.get("type").is_some() => {
                            out.push(format!("{path}: unknown field"));
                        }
                        Some(sub @ Value::Object(_)) => self.check(sub, field, &path, false, depth + 1, out),
                        _ => {}
                    },
                }
            }
        }
    }
}

fn collect_refs(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (k, v) in map {
                if k == "$ref"
                    && let Some(name) = v.as_str().and_then(|r| r.strip_prefix("#/types/"))
                {
                    out.insert(name.to_owned());
                }
                collect_refs(v, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|v| collect_refs(v, out)),
        _ => {}
    }
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0000_0100_0000_01b3))
}

/// Whether a Mac answers a method, as far as the phone can tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Support {
    Yes,
    No,
    /// An older Mac with no `api` service, and nothing else says: try it and read the error.
    Unknown,
}

/// What the phone knows about the Mac it is connected to. Built from `api list` when the Mac
/// has it, or from the `version` service's capabilities when it does not (a Mac from before
/// this contract replies `unknown_service` to `api`).
#[derive(Clone, Debug, Default)]
pub struct Discovery {
    methods: Option<BTreeSet<String>>,
    capabilities: BTreeSet<String>,
    digest: Option<String>,
}

impl Discovery {
    /// From an `api list` reply plus the `version` capabilities.
    pub fn from_list(list: &Value, capabilities: impl IntoIterator<Item = String>) -> Self {
        let methods = list
            .get("methods")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| m.get("name")?.as_str().map(str::to_owned))
            .collect();
        Self {
            methods: Some(methods),
            capabilities: capabilities.into_iter().collect(),
            digest: list.get("digest").and_then(Value::as_str).map(str::to_owned),
        }
    }

    /// A Mac with no `api` service: only its `version` capabilities are known.
    pub fn legacy(capabilities: impl IntoIterator<Item = String>) -> Self {
        Self { methods: None, capabilities: capabilities.into_iter().collect(), digest: None }
    }

    pub fn digest(&self) -> Option<&str> {
        self.digest.as_deref()
    }

    pub fn has_capability(&self, name: &str) -> bool {
        self.capabilities.contains(name)
    }

    pub fn supports(&self, method: &str) -> Support {
        match &self.methods {
            Some(methods) if methods.contains(method) => Support::Yes,
            Some(_) => Support::No,
            None => Support::Unknown,
        }
    }

    /// A method's field the phone wants to send that carries `x-capability` in this phone's
    /// contract: yes only if the Mac advertises that capability.
    pub fn supports_field(&self, method: &str, field: &str) -> Support {
        let Some(schema) = contract().method(method).and_then(|m| m.get("params")) else {
            return self.supports(method);
        };
        let schema = contract().resolve(schema);
        let Some(field) = schema.get("properties").and_then(|p| p.get(field)) else {
            return Support::No;
        };
        match field.get("x-capability").and_then(Value::as_str) {
            Some(cap) if self.has_capability(cap) => Support::Yes,
            Some(_) => Support::No,
            None => self.supports(method),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny() -> Contract {
        Contract::from_value(json!({
            "contract": CONTRACT, "version": 1,
            "methods": [
                {"name": "daemon/ping", "service": "daemon", "kind": "request",
                 "params": {"type": "object", "properties": {"n": {"type": "integer"},
                            "mode": {"$ref": "#/types/daemon.Mode"}},
                            "required": ["n"], "additionalProperties": false},
                 "result": {"type": "object", "properties": {}}},
                {"name": "link/version", "service": "version", "kind": "request", "params": true,
                 "capability": "x"}
            ],
            "types": {"daemon.Mode": {"enum": ["a", "b"]}, "daemon.Unused": {"type": "string"}}
        }))
    }

    #[test]
    fn strict_requests() {
        let c = tiny();
        assert!(
            c.check_request("daemon/ping", &json!({"id": 1, "cmd": "ping", "n": 3, "mode": "a"})).is_empty()
        );
        assert_eq!(
            c.check_request("daemon/ping", &json!({"n": 3, "extra": true})),
            vec!["/extra: unknown field"]
        );
        assert_eq!(c.check_request("daemon/ping", &json!({})), vec!["/n: required"]);
        assert_eq!(c.check_request("daemon/ping", &json!({"n": 1, "mode": "z"})).len(), 1);
        assert!(c.check_request("link/version", &json!({"anything": 1})).is_empty());
        assert!(c.check_request("daemon/unlisted", &json!({"anything": 1})).is_empty());
    }

    #[test]
    fn describe_carries_reached_types_only() {
        let c = tiny();
        let d = c.describe("daemon/ping").unwrap();
        assert!(d["types"].get("daemon.Mode").is_some());
        assert!(d["types"].get("daemon.Unused").is_none());
        assert!(c.describe("nope").is_none());
    }

    #[test]
    fn list_filters_and_digest_is_stable() {
        let c = tiny();
        let all = c.list(|_| true);
        assert_eq!(all["methods"].as_array().unwrap().len(), 2);
        let some = c.list(|m| m.get("capability").is_none());
        assert_eq!(some["methods"].as_array().unwrap().len(), 1);
        assert_eq!(c.digest(), tiny().digest());
        assert!(c.llms_txt(|_| true).contains("daemon/ping (request)"));
    }

    #[test]
    fn discovery_without_api_is_unknown() {
        let old = Discovery::legacy(["chief-v1".to_owned()]);
        assert_eq!(old.supports("daemon/ping"), Support::Unknown);
        assert!(old.has_capability("chief-v1"));
        let new = Discovery::from_list(&json!({"methods": [{"name": "daemon/ping"}], "digest": "d"}), []);
        assert_eq!(new.supports("daemon/ping"), Support::Yes);
        assert_eq!(new.supports("daemon/pong"), Support::No);
        assert_eq!(new.digest(), Some("d"));
    }

    #[test]
    fn embedded_contract_parses() {
        let c = contract();
        assert_eq!(c.document()["contract"], CONTRACT);
        assert!(c.method("link/version").is_some());
    }
}
