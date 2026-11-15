//! What a user row says of its prompt and its sender (decision 231), read from its `user_message`
//! record as the view's reader does (direct.ts; multiplayer/participants.ts `promptAuthor`,
//! conversation/incomingMessage.ts `cliHost` and `recordedAgentText`, sentFromHarness.ts), and
//! the start of a prompt's text that its turn's group row names (decision 235).
use serde::Deserialize;
use serde_json::{Map, Value, value::RawValue};
use std::borrow::Cow;

/// Longest name the view draws, in characters.
const MAX_NAME: usize = 64;
/// Longest id kept; a longer one is no person the hub would stamp.
const MAX_ID: usize = 256;
/// Longest picture kept, in UTF-8 bytes: the hub stamps an https link of at most this; an inline
/// one is held to it too, so a held row stays small.
const MAX_AVATAR_URL: usize = 1024;
/// Longest sender claim field, in UTF-16 units; a longer one is dropped, not cut.
const MAX_CLAIM: usize = 128;
/// The bytes of a prompt's text its turn's group row names (decision 235).
pub(super) const HEAD_BYTES: usize = 160;

/// The record's keys a user row's sender fields come from.
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct Said<'a> {
    #[serde(borrow)]
    client: Option<&'a RawValue>,
    #[serde(borrow)]
    agent_text: Option<&'a RawValue>,
    #[serde(rename = "_meta", borrow)]
    meta: SaidMeta<'a>,
    /// An older record's sender projection and harness, beside its provenance.
    sender: Value,
    from_harness: Value,
    #[serde(borrow)]
    pub inline_parts: Option<&'a RawValue>,
    #[serde(borrow)]
    pub pasted: Option<&'a RawValue>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
struct SaidMeta<'a> {
    #[serde(borrow)]
    provenance: Option<&'a RawValue>,
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Provenance {
    kind: String,
    from: Value,
    from_name: Value,
    from_short_name: Value,
    from_avatar: Value,
    from_harness: Value,
    from_session_id: Value,
    from_relay: Value,
    claimed: Value,
    sender: Value,
    program: Value,
    verified: Value,
    verified_by: Value,
}

/// A sender who only named itself (`--from`), as the hub records its `from`.
const NAMED_SENDER: &str = "fromAgent";
/// The hub's own messages with words for the agent: they draw as its message.
const ACPMUX_MESSAGE_KINDS: &[&str] = &["inbox_digest", "turn_cap"];
/// The hub's continuations of a failed turn or subagent, and its cache compaction: no one's prompt.
const BOOKKEEPING_KINDS: &[&str] = &["auto_resume", "cache_compact", "subagent_retry"];
/// Sessions here that send messages, which name their sender by its session.
const SESSION_KINDS: &[&str] =
    &["lane_report", "session_message", "subsession_message", "task_result"];
/// The longest proven sender name kept, in bytes.
const MAX_SENDER_BYTES: usize = 256;
/// The longest harness word kept, in bytes.
const MAX_HARNESS_BYTES: usize = 64;
/// A relay or machine name as the hub takes it (prompt_provenance.rs `harness_fits`).
fn relay_name(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// What a user row says of who sent its prompt (decision 244: what the record proves).
#[derive(Default)]
pub(super) struct Sender {
    /// Compact JSON values by field name.
    pub fields: Vec<(&'static str, String)>,
    /// Not the person's typed prompt (another agent's message, the hub's, bookkeeping): it names
    /// no person, client or agent text, and is no turn's prompt to recall.
    pub untyped: bool,
    /// It may carry a `sentFrom`: a typed prompt, or another agent's message.
    pub claims: bool,
    /// Strings cut at their cap.
    pub cut: u64,
}

/// The user row's fields of who sent a prompt and how.
pub(super) fn sender(said: &Said<'_>, prompt: &str) -> Sender {
    let mut out = Sender::default();
    // The Chief's task, tell, steer or restart message to a subagent (subagents.rs PROMPT_PREFIX).
    if prompt.starts_with("optchat-") {
        out.fields.push(("from", "\"chief\"".to_owned()));
    }
    let provenance: Option<Provenance> =
        said.meta.provenance.and_then(|raw| serde_json::from_str(raw.get()).ok());
    if let Some(incoming) = provenance.as_ref().and_then(|p| incoming(p, said, &mut out.cut)) {
        out.claims = incoming.get("kind").and_then(Value::as_str) == Some("message");
        out.untyped = true;
        out.fields.push(("incoming", json(incoming)));
        return out;
    }
    out.claims = true;
    if let Some(provenance) = &provenance
        && provenance.kind == "person_message"
        && let Some(author) =
            participant(&provenance.from, &provenance.from_name, &provenance.from_avatar, true)
    {
        out.fields.push(("author", author));
    }
    if let Some(host) = said.client.and_then(text).as_deref().and_then(cli_host) {
        out.fields.push(("viaCli", json(Value::String(host.to_owned()))));
    }
    if let Some(agent_text) = said.agent_text.and_then(agent_text) {
        out.fields.push(("agentText", agent_text));
    }
    out
}

/// `incoming`: the kind of prompt the record proves it is, when it is not the person's own, and
/// its sender as the record names it: `{kind, sender?: {name?, harness?, relay?, unverified?}}`.
/// How the text reads (a relay label, a signature, an addressed line) is the page's to add
/// (decision 244 b), so a record that proves nothing reads as typed here.
fn incoming(p: &Provenance, said: &Said<'_>, cut: &mut u64) -> Option<Value> {
    let kind = p.kind.as_str();
    let from = p.from.as_str().filter(|from| !from.is_empty());
    let message = |name: Option<String>, cut: &mut u64| {
        let mut object = Map::new();
        object.insert("kind".into(), Value::String("message".into()));
        if let Some(sender) = proven_sender(p, said, name, cut) {
            object.insert("sender".into(), sender);
        }
        Some(Value::Object(object))
    };
    let just = |kind: &str| {
        let mut object = Map::new();
        object.insert("kind".into(), Value::String(kind.into()));
        Some(Value::Object(object))
    };
    if BOOKKEEPING_KINDS.contains(&kind) {
        return just("hidden");
    }
    if kind == "inbox_notice" {
        return just("inbox");
    }
    if ACPMUX_MESSAGE_KINDS.contains(&kind) && p.from.is_null() {
        let mut object = Map::new();
        object.insert("kind".into(), Value::String("message".into()));
        object.insert("sender".into(), serde_json::json!({"name": "acpmux"}));
        return Some(Value::Object(object));
    }
    if SESSION_KINDS.contains(&kind)
        && let Some(from) = from
    {
        let name = word(&p.from_short_name).or_else(|| word(&p.from_name)).unwrap_or(from);
        return message(Some(name.to_owned()), cut);
    }
    if kind == "agent_message"
        && let Some(from) = from
        && from != NAMED_SENDER
    {
        return message(Some(word(&p.from_name).unwrap_or(from).to_owned()), cut);
    }
    // A sender that only named itself, a digest of messages, a tool's notice, or no proof at all:
    // another agent's, never the person's; the name it gives is in its text.
    if matches!(kind, "agent_message" | "agent_digest" | "notice" | "who_else" | "unverified") {
        let program = p.program.get("name").and_then(Value::as_str).map(str::trim);
        let name = (kind == "unverified").then_some(program).flatten().filter(|n| !n.is_empty());
        return message(name.map(str::to_owned), cut);
    }
    None
}

/// The sender as the record proves it, as the view's `withSender` reads it (senderIdentity.ts):
/// the name bare of an older hub's unverified suffix, the harness it names, a relayed sender's
/// whole address, and `unverified` unless the hub verified it.
fn proven_sender(
    p: &Provenance,
    said: &Said<'_>,
    name: Option<String>,
    cut: &mut u64,
) -> Option<Value> {
    let record = if p.sender.is_object() { &p.sender } else { &said.sender };
    let record = record.as_object();
    let verification = record.and_then(|r| match r.get("verification").and_then(Value::as_str) {
        Some(v @ ("verified" | "declared" | "legacy")) => Some(v),
        _ if r.get("authenticated") == Some(&Value::Bool(true)) => Some("verified"),
        _ if r.get("labelDeclared") == Some(&Value::Bool(true))
            || r.get("authenticated") == Some(&Value::Bool(false)) =>
        {
            Some("declared")
        }
        _ => None,
    });
    let suffix = " (self-declared, unauthenticated)";
    let (name, declared) = match name {
        Some(name) => {
            let trimmed = name.trim_end();
            let bare = trimmed
                .len()
                .checked_sub(suffix.len())
                .filter(|at| {
                    trimmed.get(*at..).is_some_and(|tail| tail.eq_ignore_ascii_case(suffix))
                })
                .and_then(|at| trimmed.get(..at));
            match bare {
                Some(bare) => (Some(bare.trim().to_owned()), true),
                None => (Some(name.trim().to_owned()), false),
            }
        }
        None => (None, false),
    };
    let authenticated = word(&p.from_session_id).is_some() || relay_proof(&p.from_relay).is_some();
    let host_token =
        p.verified == Value::Bool(true) && p.verified_by.as_str() == Some("host-token");
    let unverified = !(record.is_none() && (authenticated || host_token))
        && match verification {
            Some(v) => v != "verified",
            None => declared || p.from.as_str() == Some(NAMED_SENDER) || p.kind == "unverified",
        };
    let claimed_harness = p.claimed.get("fromHarness");
    let harness = [Some(&p.from_harness), claimed_harness, Some(&said.from_harness)]
        .into_iter()
        .flatten()
        .find_map(word)
        .or_else(|| record.and_then(|r| r.get("harness")).and_then(word));
    let relay_of = |relay: Option<&Value>| {
        let machine = relay?.get("machine").and_then(word)?;
        let session = relay?.get("session").and_then(word)?;
        Some(format!("{machine}/{session}"))
    };
    let relay = relay_of(record.and_then(|r| r.get("relay")))
        .or_else(|| authenticated.then(|| relay_of(Some(&p.from_relay))).flatten());
    let mut sender = Map::new();
    let mut put = |key: &str, value: &str, cap: usize| {
        let kept = super::cut(value, cap);
        if kept.len() < value.len() {
            *cut = cut.saturating_add(1);
        }
        sender.insert(key.into(), Value::String(kept.to_owned()));
    };
    if let Some(name) = name.as_deref().filter(|name| !name.is_empty()) {
        put("name", name, MAX_SENDER_BYTES);
    }
    if let Some(harness) = harness {
        put("harness", harness, MAX_HARNESS_BYTES);
    }
    if let Some(relay) = &relay {
        put("relay", relay, MAX_SENDER_BYTES);
    }
    if unverified {
        sender.insert("unverified".into(), Value::Bool(true));
    }
    (!sender.is_empty()).then_some(Value::Object(sender))
}

/// A relay's record of where it took the message (`fromRelay`), its relay and machine well formed.
fn relay_proof(relay: &Value) -> Option<()> {
    let by = relay.get("by")?.as_str()?;
    let machine = relay.get("machine")?.as_str()?;
    (relay_name(by) && relay_name(machine)).then_some(())
}

/// A string's trimmed words, or none.
fn word(value: &Value) -> Option<&str> {
    value.as_str().map(str::trim).filter(|value| !value.is_empty())
}

/// A person as the view draws one (`participant`): the id kept whole, the name without hidden
/// characters on one line of at most 64 characters, and a picture that is an inline image or,
/// with `links`, an https link.
pub(super) fn participant(id: &Value, name: &Value, avatar: &Value, links: bool) -> Option<String> {
    let id = id.as_str().map(str::trim).filter(|id| !id.is_empty() && id.len() <= MAX_ID)?;
    let name = name.as_str().and_then(display_name).or_else(|| display_name(id));
    let mut person = Map::new();
    person.insert("id".into(), Value::String(id.into()));
    person.insert("name".into(), Value::String(name.unwrap_or_else(|| "?".into())));
    if let Some(avatar) = avatar.as_str().filter(|avatar| picture(avatar, links)) {
        person.insert("avatar".into(), Value::String(avatar.into()));
    }
    Some(json(Value::Object(person)))
}

/// A character a name may not hold, as the hub stamps names (hub/composers.rs `hidden`).
fn hidden(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{FEFF}')
        || ('\u{200B}'..='\u{200F}').contains(&c)
        || ('\u{202A}'..='\u{202E}').contains(&c)
        || ('\u{2060}'..='\u{206F}').contains(&c)
        || ('\u{FFF9}'..='\u{FFFB}').contains(&c)
}

fn display_name(value: &str) -> Option<String> {
    let mut shown = String::new();
    let mut space = false;
    for c in value.chars().filter(|c| !hidden(*c)) {
        if c.is_whitespace() {
            space = !shown.is_empty();
            continue;
        }
        if space {
            shown.push(' ');
            space = false;
        }
        shown.push(c);
    }
    let shown: String = shown.chars().take(MAX_NAME).collect();
    (!shown.is_empty()).then_some(shown)
}

fn picture(value: &str, links: bool) -> bool {
    if value.len() > MAX_AVATAR_URL {
        return false;
    }
    ["png", "jpeg", "gif", "webp"]
        .iter()
        .any(|kind| value.starts_with(&format!("data:image/{kind};base64,")))
        || (links && https(value))
}

/// An absolute https link with a host.
fn https(value: &str) -> bool {
    value.strip_prefix("https://").is_some_and(|rest| {
        let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
        !host.is_empty() && !value.chars().any(|c| c.is_whitespace() || c.is_control())
    })
}

/// The machine a person's own `acpmux send` ran on, from the client the hub recorded
/// (`acpmux-cli#…@build-host`, through a peer `acpmux-peer#…`, or the outbox's).
fn cli_host(client: &str) -> Option<&str> {
    let rest = ["acpmux-cli#", "acpmux-peer#", "acpmux-outbox#"]
        .iter()
        .find_map(|prefix| client.strip_prefix(prefix))?;
    let (connection, host) = rest.rsplit_once('@')?;
    let host_ok = (1..=64).contains(&host.len())
        && host.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    (!connection.contains(['@', ' ', '\t', '\n', '\r']) && host_ok).then_some(host)
}

/// `agentText`: part of the person's typed text reads as another agent's output, with the agent
/// it names (trimmed, at most 64 characters) if any. Anything but an object is none.
fn agent_text(raw: &RawValue) -> Option<String> {
    let Ok(Value::Object(said)) = serde_json::from_str::<Value>(raw.get()) else {
        return None;
    };
    let mut kept = Map::new();
    if let Some(from) = said.get("from").and_then(Value::as_str).map(str::trim)
        && !from.is_empty()
    {
        kept.insert("from".into(), Value::String(from.chars().take(MAX_NAME).collect()));
    }
    Some(json(Value::Object(kept)))
}

/// A `sender_claim`: where a prompt was sent from, as its harness says and the hub checked
/// (sentFromHarness.ts `sentFrom`). The prompt it names, and the view's `SentFrom` value.
pub(super) fn sent_from(raw: &RawValue) -> Option<(String, String)> {
    let Ok(Value::Object(record)) = serde_json::from_str::<Value>(raw.get()) else {
        return None;
    };
    let field = |object: Option<&Value>, key: &str| -> Option<String> { claim(object?.get(key)?) };
    let prompt = claim(record.get("promptId")?)?;
    let claimed = record.get("claimed").filter(|claimed| claimed.is_object());
    let harness = field(claimed, "harness")?;
    let checked_raw = record.get("checked").filter(|checked| checked.is_object());
    let mut checked = Map::new();
    for key in ["harness", "app", "signedBy"] {
        if let Some(value) = field(checked_raw, key) {
            checked.insert(key.into(), Value::String(value));
        }
    }
    let entrypoint = field(claimed, "entrypoint");
    let app = field(claimed, "app");
    let checked_app = checked.get("app").and_then(Value::as_str);
    let desktop = harness == "claude-code"
        && (entrypoint.as_deref() == Some("claude-desktop")
            || app.as_deref() == Some("Claude.app"));
    let confirmed = checked_raw.is_some()
        && (checked.get("harness").and_then(Value::as_str) == Some(harness.as_str())
            || (app.is_some() && checked_app == app.as_deref())
            || (desktop && checked_app == Some("Claude.app")))
        && (app.is_none() || checked_app == app.as_deref())
        && (!desktop || checked_app == Some("Claude.app"));
    let shown_app = app.as_deref().or(if confirmed { checked_app } else { None });
    let label = match harness.as_str() {
        "claude-code"
            if entrypoint.as_deref() == Some("claude-desktop")
                || shown_app == Some("Claude.app") =>
        {
            "Claude desktop".to_owned()
        }
        "claude-code" if entrypoint.as_deref().is_some_and(|e| e.starts_with("sdk")) => {
            "Claude Agent SDK".to_owned()
        }
        "claude-code" => "Claude Code".to_owned(),
        "codex" => "Codex".to_owned(),
        other => other.to_owned(),
    };
    let mut from = Map::new();
    from.insert("promptId".into(), Value::String(prompt.clone()));
    from.insert("harness".into(), Value::String(harness));
    from.insert("label".into(), Value::String(label));
    for key in ["sessionId", "hostSessionId"] {
        if let Some(value) = field(claimed, key) {
            from.insert(key.into(), Value::String(value));
        }
    }
    if !checked.is_empty() {
        from.insert("checked".into(), Value::Object(checked));
    }
    from.insert("confirmed".into(), Value::Bool(confirmed));
    Some((prompt, json(Value::Object(from))))
}

/// A claim's field: a trimmed, non-empty string of at most 128 UTF-16 units with no control
/// character, else none (dropped, never cut).
fn claim(value: &Value) -> Option<String> {
    let value = value.as_str()?.trim();
    let ok = !value.is_empty()
        && value.encode_utf16().count() <= MAX_CLAIM
        && !value.chars().any(char::is_control);
    ok.then(|| value.to_owned())
}

/// At most `cap` bytes from the start of a JSON string's text, cut on a character, decoding
/// only what it keeps: a long prompt costs no more than its head.
pub(super) fn head(raw: &RawValue, cap: usize) -> Option<String> {
    let inner = raw.get().strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        let decoded = match c {
            '"' => break,
            '\\' => match chars.next()? {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => '\u{8}',
                'f' => '\u{c}',
                'u' => {
                    let unit = hex4(&mut chars)?;
                    if let Some(high) = unit.checked_sub(0xD800).filter(|high| *high < 0x400) {
                        let low = (chars.next()? == '\\' && chars.next()? == 'u')
                            .then(|| hex4(&mut chars))
                            .flatten()?
                            .checked_sub(0xDC00)
                            .filter(|low| *low < 0x400)?;
                        char::from_u32(0x10000 | (high << 10) | low)?
                    } else {
                        char::from_u32(unit).unwrap_or('\u{FFFD}')
                    }
                }
                other => other,
            },
            c => c,
        };
        if out.len().saturating_add(decoded.len_utf8()) > cap {
            break;
        }
        out.push(decoded);
    }
    Some(out)
}

fn hex4(chars: &mut std::str::Chars<'_>) -> Option<u32> {
    let mut unit = 0;
    for _ in 0..4 {
        unit = (unit << 4) | chars.next()?.to_digit(16)?;
    }
    Some(unit)
}

fn text(raw: &RawValue) -> Option<Cow<'_, str>> {
    serde_json::from_str(raw.get()).ok()
}

fn json(value: Value) -> String {
    serde_json::to_string(&value).unwrap_or_else(|_| "null".into())
}
