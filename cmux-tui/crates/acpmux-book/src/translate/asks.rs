//! Ask rows (decision 245): a permission, a question or a secret the agent asked the person for,
//! open from its request until its decision settles it. The row carries the record's inputs raw
//! (`request`, then `outcome`) and its small proven facts as fields; the page builds the view's
//! `AcpmuxPermission` and a question's answered state from the same bytes (v1's
//! `permissionFromMessage` and `decidedQuestion`). No row holds localized text.
use super::{BodyField, Error, OwnedRow, State, input, prompt_hash, user};
use crate::row::RowKind;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, value::RawValue};

/// The most asks open at once; past it the oldest settles undecided, counted.
pub(super) const MAX_OPEN_ASKS: usize = 32;
/// The most bytes of fields the open asks hold, so 32 fit the translator's segment.
const MAX_ASK_BYTES: usize = 8 * 1024;
/// The most option kinds an open permission keeps, by option id hash.
const MAX_OPTIONS: usize = 8;
/// A permission's title, as its receipt names it.
const MAX_TITLE_BYTES: usize = 160;
/// A secret's name and a host's, a mode's id, a decision word.
const MAX_WORD_BYTES: usize = 64;
/// A secret's or an elevation's reason.
const MAX_REASON_BYTES: usize = 512;
/// An elevation's command: its words, and their bytes together.
const MAX_ARGV: usize = 16;
const MAX_ARGV_BYTES: usize = 1024;

/// An option's kind, as the view's `permissionOptionKind` reads it (permissions/prompt.ts).
const ONCE: u8 = 0;
const ALWAYS: u8 = 1;
const DENY: u8 = 2;
const OTHER: u8 = 3;

/// An open ask: its row, and its options' kinds by id hash.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Ask {
    pub row: OwnedRow,
    options: Vec<(u64, u8)>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct AskRecord<'a> {
    permission_id: Value,
    secret_id: Value,
    #[serde(borrow)]
    request: Option<&'a RawValue>,
    group_id: Value,
    turn_id: Value,
    name: Value,
    reason: Value,
    argv: Value,
    host: Value,
    timeout_secs: Value,
    #[serde(borrow)]
    outcome: Option<&'a RawValue>,
    answered_by: Value,
    option_id: Value,
    full_access: Value,
    cancelled: Value,
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Request {
    title: Value,
    tool_call: Value,
    options: Value,
}

/// The key an ask is held by: its kind's id, hashed.
fn key(prefix: &str, id: &str) -> u64 {
    prompt_hash(&format!("{prefix}:{id}"))
}

impl State {
    /// `permission_request`: a permission, or a question when its tool call carries the hub's
    /// normalized question (hub/questions.rs `normalize`). Repeated (a reissue) it opens nothing.
    pub(super) fn ask_permission(
        &mut self,
        record: &AskRecord<'_>,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        let Some(id) = record.permission_id.as_str().filter(|id| !id.is_empty()) else {
            return Ok(());
        };
        let hash = key("permission", id);
        if self.asks.contains_key(&hash) {
            return Ok(());
        }
        let request: Request =
            record.request.and_then(|raw| serde_json::from_str(raw.get()).ok()).unwrap_or_default();
        let question =
            request.tool_call.pointer("/_meta/acpmux/question").is_some_and(Value::is_object);
        let mut row = self.row(RowKind::Ask, out)?;
        row.fields.insert("ask".into(), json_str(if question { "question" } else { "permission" }));
        self.capped(&mut row, "permissionId", id, super::MAX_KEY_BYTES);
        for (field, value) in [("groupId", &record.group_id), ("turnId", &record.turn_id)] {
            if let Some(value) = value.as_str().filter(|value| !value.is_empty()) {
                self.capped(&mut row, field, value, super::MAX_KEY_BYTES);
            }
        }
        // What a settled permission's receipt reads (PermissionRecordRow.tsx): its title.
        let title = request
            .title
            .as_str()
            .or_else(|| request.tool_call.get("title").and_then(Value::as_str))
            .map(str::trim)
            .filter(|title| !title.is_empty());
        if let Some(title) = title {
            self.capped(&mut row, "title", title, MAX_TITLE_BYTES);
        }
        let listed = request.options.as_array().map_or(0, Vec::len);
        let options: Vec<(u64, u8)> = request
            .options
            .as_array()
            .map(|options| {
                options
                    .iter()
                    .filter_map(|option| {
                        let id = option.get("optionId").or_else(|| option.get("id"))?;
                        let id = id.as_str()?.trim();
                        (!id.is_empty()).then(|| {
                            let word = |key: &str| {
                                option.get(key).and_then(Value::as_str).unwrap_or_default()
                            };
                            (prompt_hash(id), option_kind(word("kind"), id, word("name")))
                        })
                    })
                    .take(MAX_OPTIONS)
                    .collect()
            })
            .unwrap_or_default();
        // An option past the 8 kept reads as `answered`, whatever its kind: count the cut.
        if options.len() == MAX_OPTIONS && listed > MAX_OPTIONS {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        self.open_ask(hash, row, options, record.request.map(|raw| (BodyField::Request, raw)), out);
        Ok(())
    }

    /// `secret_request` and `elevation_request`: the person's secret, or their OK to run a
    /// command as root (`name` "sudo", with its command, host and time limit).
    pub(super) fn ask_secret(
        &mut self,
        record: &AskRecord<'_>,
        elevation: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        let Some(id) = record.secret_id.as_str().filter(|id| !id.is_empty()) else {
            return Ok(());
        };
        let hash = key("secret", id);
        if self.asks.contains_key(&hash) {
            return Ok(());
        }
        let mut row = self.row(RowKind::Ask, out)?;
        row.fields.insert("ask".into(), json_str("secret"));
        self.capped(&mut row, "secretId", id, super::MAX_KEY_BYTES);
        let name = if elevation { Some("sudo") } else { record.name.as_str() };
        if let Some(name) = name.filter(|name| !name.is_empty()) {
            self.capped(&mut row, "name", name, MAX_WORD_BYTES);
        }
        if let Some(reason) = record.reason.as_str().filter(|reason| !reason.is_empty()) {
            self.capped(&mut row, "reason", reason, MAX_REASON_BYTES);
        }
        if elevation {
            let mut argv = Vec::new();
            let mut bytes = 0usize;
            let words = record.argv.as_array().map(Vec::as_slice).unwrap_or_default();
            for word in words {
                let word = word.as_str().map_or_else(|| word.to_string(), str::to_owned);
                let left = MAX_ARGV_BYTES.saturating_sub(bytes);
                if argv.len() == MAX_ARGV || left == 0 {
                    self.cut_fields = self.cut_fields.saturating_add(1);
                    break;
                }
                let kept = super::cut(&word, left).to_owned();
                if kept.len() < word.len() {
                    self.cut_fields = self.cut_fields.saturating_add(1);
                }
                bytes = bytes.saturating_add(kept.len());
                argv.push(Value::String(kept));
            }
            row.fields.insert("argv".into(), json(Value::Array(argv)));
            if let Some(host) = record.host.as_str().filter(|host| !host.is_empty()) {
                self.capped(&mut row, "host", host, MAX_WORD_BYTES);
            }
            if let Some(secs) = record.timeout_secs.as_u64() {
                row.fields.insert("timeoutSecs".into(), secs.to_string());
            }
        }
        self.open_ask(hash, row, Vec::new(), None, out);
        Ok(())
    }

    /// `permission_decision`: the person's answer (or the agent's withdrawal, `cancelled`).
    pub(super) fn decide_permission(
        &mut self,
        record: &AskRecord<'_>,
        out: &mut input::Output<'_>,
    ) {
        let id = record.permission_id.as_str().unwrap_or_default();
        let Some(Ask { mut row, options }) = self.take_ask(key("permission", id), true) else {
            return;
        };
        let outcome: Value =
            record.outcome.and_then(|raw| serde_json::from_str(raw.get()).ok()).unwrap_or_default();
        let chosen = (outcome.get("outcome").and_then(Value::as_str) == Some("selected"))
            .then(|| outcome.get("optionId").and_then(Value::as_str))
            .flatten();
        row.fields.insert("decision".into(), self.decision(chosen, &options));
        if let Some(by) = answered_by(&record.answered_by) {
            row.fields.insert("answeredBy".into(), by);
        }
        if let Some(raw) = record.outcome {
            out.body(row.id, BodyField::Outcome, false, raw);
        }
        settle(row, out);
    }

    /// `permission_auto` for an ask the person was shown: a switch to full access (`fullAccess`,
    /// its mode's id), a policy's answer by its option, or its cancel. Another auto opened no ask.
    pub(super) fn decide_auto(&mut self, record: &AskRecord<'_>, out: &mut input::Output<'_>) {
        let id = record.permission_id.as_str().unwrap_or_default();
        let Some(Ask { mut row, options }) = self.take_ask(key("permission", id), false) else {
            return;
        };
        let decision = if let Some(mode) = record.full_access.as_str() {
            let mut kept = Map::new();
            kept.insert("kind".into(), Value::String("fullAccess".into()));
            kept.insert("mode".into(), Value::String(self.cut_counted(mode, MAX_WORD_BYTES)));
            json(Value::Object(kept))
        } else {
            let chosen = (record.cancelled != Value::Bool(true))
                .then(|| record.option_id.as_str())
                .flatten();
            self.decision(chosen, &options)
        };
        row.fields.insert("decision".into(), decision);
        settle(row, out);
    }

    /// `secret_decision` and `elevation_decision`: the outcome's word (provided, declined,
    /// approved, denied, cancelled); a secret's value is never in a record.
    pub(super) fn decide_secret(&mut self, record: &AskRecord<'_>, out: &mut input::Output<'_>) {
        let id = record.secret_id.as_str().unwrap_or_default();
        let Some(Ask { mut row, .. }) = self.take_ask(key("secret", id), true) else {
            return;
        };
        let word = record
            .outcome
            .and_then(|raw| serde_json::from_str::<String>(raw.get()).ok())
            .unwrap_or_else(|| "cancelled".into());
        let mut decision = Map::new();
        decision.insert("kind".into(), Value::String(self.cut_counted(&word, MAX_WORD_BYTES)));
        row.fields.insert("decision".into(), json(Value::Object(decision)));
        settle(row, out);
    }

    /// The view's `PermissionDecision` for the option chosen, by its kind: none chosen is
    /// `cancelled`; an option of no allow or deny kind, or one not kept, is `answered` with its id.
    fn decision(&mut self, chosen: Option<&str>, options: &[(u64, u8)]) -> String {
        let Some(chosen) = chosen else {
            return r#"{"kind":"cancelled"}"#.into();
        };
        let kind = options.iter().find(|(hash, _)| *hash == prompt_hash(chosen)).map(|(_, k)| *k);
        match kind {
            Some(ONCE) => r#"{"kind":"allowed"}"#.into(),
            Some(ALWAYS) => r#"{"kind":"allowedAlways"}"#.into(),
            Some(DENY) => r#"{"kind":"denied"}"#.into(),
            _ => {
                let mut answered = Map::new();
                answered.insert("kind".into(), Value::String("answered".into()));
                answered.insert(
                    "option".into(),
                    Value::String(self.cut_counted(chosen, MAX_WORD_BYTES)),
                );
                json(Value::Object(answered))
            }
        }
    }

    fn open_ask(
        &mut self,
        hash: u64,
        row: OwnedRow,
        options: Vec<(u64, u8)>,
        body: Option<(BodyField, &RawValue)>,
        out: &mut input::Output<'_>,
    ) {
        let bytes = super::fields_bytes(&row);
        while !self.asks.is_empty()
            && (self.asks.len() >= MAX_OPEN_ASKS
                || self.held_ask_bytes().saturating_add(bytes) > MAX_ASK_BYTES)
            && let Some(old) = self.asks.iter().min_by_key(|(_, ask)| ask.row.id).map(|(h, _)| *h)
        {
            if let Some(ask) = self.asks.remove(&old) {
                settle(ask.row, out);
                self.forced_asks = self.forced_asks.saturating_add(1);
            }
        }
        out.row(&row);
        if let Some((field, raw)) = body {
            out.body(row.id, field, false, raw);
        }
        self.asks.insert(hash, Ask { row, options });
    }

    /// The open ask a decision names, or none. A person's or a secret's decision for one the
    /// bound settled already, or one this book never saw asked, is counted (`counted`). An
    /// automatic answer is not: the hub writes a policy's answer before its request, and that
    /// request then opens no ask.
    fn take_ask(&mut self, hash: u64, counted: bool) -> Option<Ask> {
        let ask = self.asks.remove(&hash);
        if ask.is_none() && counted {
            self.unplaced_decisions = self.unplaced_decisions.saturating_add(1);
        }
        ask
    }

    fn held_ask_bytes(&self) -> usize {
        self.asks.values().map(|ask| super::fields_bytes(&ask.row)).fold(0, usize::saturating_add)
    }

    /// A string field cut at `cap`, its cut counted.
    fn capped(&mut self, row: &mut OwnedRow, key: &str, value: &str, cap: usize) {
        if row.field_capped(key, value, cap) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
    }

    fn cut_counted(&mut self, value: &str, cap: usize) -> String {
        let kept = super::cut(value, cap);
        if kept.len() < value.len() {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        kept.to_owned()
    }
}

fn settle(mut row: OwnedRow, out: &mut input::Output<'_>) {
    row.open = false;
    out.row(&row);
}

/// Who answered, as the view's `answeredBy` reads it: a person `{id, name, avatar?}` with an
/// inline picture only; a session's or a device's answer names no person.
fn answered_by(value: &Value) -> Option<String> {
    let by = value.as_object()?;
    if by.get("session").is_some_and(Value::is_string)
        || by.get("device").is_some_and(Value::is_string)
    {
        return None;
    }
    let none = Value::Null;
    user::participant(
        by.get("id").unwrap_or(&none),
        by.get("name").unwrap_or(&none),
        by.get("avatar").unwrap_or(&none),
        false,
    )
}

/// An option's kind from its `kind`, else from the words of its kind, id and name.
fn option_kind(kind: &str, id: &str, name: &str) -> u8 {
    let kind = kind.to_lowercase();
    match kind.as_str() {
        "allow_once" => return ONCE,
        "allow_always" => return ALWAYS,
        k if k.starts_with("reject") => return DENY,
        k if !k.is_empty() && !k.starts_with("allow") => return OTHER,
        _ => {}
    }
    let words = format!("{kind} {id} {name}").to_lowercase();
    if kind.is_empty() && (words.contains("deny") || words.contains("reject")) {
        DENY
    } else if words.contains("always") || allow_then(&words, &["forever", "permanent"]) {
        ALWAYS
    } else if allow_then(&words, &["chat", "session"]) {
        // `allow_chat`: the view reads it as allowed always.
        ALWAYS
    } else if allow_then(&words, &["once", "one"])
        || words.contains("single")
        || words.contains("approve")
    {
        ONCE
    } else {
        OTHER
    }
}

/// Whether `words` has "allow", one of `_`, ` ` or `-` or nothing, then one of `then`.
fn allow_then(words: &str, then: &[&str]) -> bool {
    words.match_indices("allow").any(|(at, _)| {
        let rest = words.get(at.saturating_add(5)..).unwrap_or_default();
        let rest = rest.strip_prefix(['_', ' ', '-']).unwrap_or(rest);
        then.iter().any(|word| rest.starts_with(word))
    })
}

fn json(value: Value) -> String {
    serde_json::to_string(&value).unwrap_or_else(|_| "null".into())
}

fn json_str(value: &str) -> String {
    json(Value::String(value.into()))
}
