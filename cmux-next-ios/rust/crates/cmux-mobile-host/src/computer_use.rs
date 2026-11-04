//! Computer Use approvals on the owner's phones (`docs/computer-use-approvals.md`,
//! "Phone wire (macOS)"). The Mac app stays the one that decides; hostd forwards:
//!
//! - App → hostd: `cu_approval {request, always}` asks every paired phone
//!   (one push, `kind: "computer_use"`); `cu_approval_done {digest}` drops the
//!   question. The same digest twice is the same question: no second push.
//! - Phone → hostd: `cu-approval-answer {digest, decision, expires_at,
//!   signature?}` on the link's `daemon` channel (answered here, never by the
//!   daemon), or a reply mailbox item of kind `computer_use`.
//! - hostd → App: `cu_approval_answer` on stdout, once per digest: the first
//!   valid answer wins and later ones are `not_pending`.
//!
//! An answer counts only from a paired phone, for a pending digest, `always`
//! only when that question offered it, with `now <= expires_at <= now + 300`,
//! and (except `deny`) signed by that phone's paired approval key over
//! [`message`]. The app checks the signature again with its own copy of the key.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use cmux_mobile_link::api::NotifyEvent;
use serde_json::{Map, Value};
use tokio::sync::watch;

use crate::control::Event;
use crate::mailbox::{ActionKind, Rejection, Reply};
use crate::pairing::DeviceTrust;

/// The domain of a phone's Computer Use decision signature.
pub const DOMAIN: &str = "cmux-cu-phone-approval-v1";
/// The furthest ahead `expires_at` may be, in seconds.
pub const MAX_LIFETIME: u64 = 300;
/// The notify `kind` of a Computer Use question.
pub const KIND: &str = "computer_use";
/// The Worker's limit for the `computerUse` object's JSON, in bytes: a larger
/// one fails the whole notify, so such a question is not pushed.
pub const MAX_COMPUTER_USE_BYTES: usize = 2048;
/// Questions held at most (pending and recently closed); past it a new one is refused.
pub const MAX_QUESTIONS: usize = 256;

/// The bytes a phone signs: the domain, then each part after one NUL.
pub fn message(phone: &str, digest: &str, decision: &str, expires_at: u64) -> Vec<u8> {
    crate::seal::joined(DOMAIN, &[phone, digest, decision, &expires_at.to_string()])
}

/// The canonical JSON of `value` (keys sorted by bytes, no whitespace, only
/// `"`, `\` and control characters escaped); `None` when it holds a number that
/// is not an integer (the contract allows integers only).
pub fn canonical(value: &Value) -> Option<String> {
    if !integers_only(value) {
        return None;
    }
    let mut out = String::new();
    crate::chief_answers::canonical_json(value, &mut out);
    Some(out)
}

fn integers_only(value: &Value) -> bool {
    match value {
        Value::Number(n) => n.is_i64() || n.is_u64(),
        Value::Array(items) => items.iter().all(integers_only),
        Value::Object(fields) => fields.values().all(integers_only),
        _ => true,
    }
}

/// The digest of a request: lowercase hex SHA-256 of the canonical JSON of the
/// request without its `digest` member.
pub fn digest(request: &Map<String, Value>) -> Option<String> {
    let mut unsigned = request.clone();
    unsigned.remove("digest");
    canonical(&Value::Object(unsigned)).map(|text| crate::seal::sha256_hex(text.as_bytes()))
}

fn is_digest(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The push's `eventId` and `permissionId`: `cu-` and the first 32 hex digits.
pub fn event_id(digest: &str) -> String {
    format!("cu-{}", &digest[..32.min(digest.len())])
}

/// A phone's decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Once,
    Session,
    Always,
    Deny,
}

impl Decision {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "once" => Some(Self::Once),
            "session" => Some(Self::Session),
            "always" => Some(Self::Always),
            "deny" => Some(Self::Deny),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Once => "once",
            Self::Session => "session",
            Self::Always => "always",
            Self::Deny => "deny",
        }
    }
}

/// Why an answer was refused (the phone's `error_code`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    NotPaired,
    NotPending,
    Refused(String),
    Expired,
    BadSignature,
}

impl Refusal {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotPaired => "not_paired",
            Self::NotPending => "not_pending",
            Self::Refused(_) => "refused",
            Self::Expired => "expired",
            Self::BadSignature => "bad_signature",
        }
    }

    fn message(&self) -> String {
        match self {
            Self::NotPaired => "this iPhone is not paired with the Mac".into(),
            Self::NotPending => "that question is not waiting".into(),
            Self::Refused(why) => why.clone(),
            Self::Expired => "the answer expired or lives too long".into(),
            Self::BadSignature => "the signature does not match this answer".into(),
        }
    }

    /// The mailbox reason of the same refusal.
    fn rejection(self) -> Rejection {
        match self {
            Self::NotPaired => Rejection::NotPaired,
            Self::NotPending => Rejection::NotPending,
            Self::Refused(why) => Rejection::Refused(why),
            Self::Expired => Rejection::Expired,
            Self::BadSignature => Rejection::BadSignature,
        }
    }
}

/// One answer as the phone sent it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub digest: String,
    pub decision: String,
    pub expires_at: u64,
    pub signature: Option<String>,
}

#[derive(Debug, Clone)]
struct Question {
    always: bool,
    answerable_until_ms: u64,
    /// Answered or dropped by the app: kept until `answerable_until_ms` so a
    /// re-sent `cu_approval` is not asked again and a late answer is `not_pending`.
    closed: bool,
}

type Pusher = Arc<dyn Fn(NotifyEvent) + Send + Sync>;

/// The questions this hostd forwards, keyed by digest (in memory only).
pub struct ComputerUse {
    trust: watch::Receiver<Option<DeviceTrust>>,
    emit: Arc<dyn Fn(Event) + Send + Sync>,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    questions: HashMap<String, Question>,
    /// Each pending question's push, kept until a pusher is attached.
    unsent: Vec<NotifyEvent>,
    pusher: Option<Pusher>,
}

impl std::fmt::Debug for ComputerUse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ComputerUse").finish_non_exhaustive()
    }
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

impl ComputerUse {
    pub fn new(trust: watch::Receiver<Option<DeviceTrust>>, emit: Arc<dyn Fn(Event) + Send + Sync>) -> Self {
        Self { trust, emit, state: Mutex::default() }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sends each question's push through `pusher` from now on, and the ones
    /// asked before it was attached that still wait.
    pub fn attach_pusher(&self, pusher: Pusher) {
        self.attach_pusher_at(pusher, now_ms());
    }

    pub fn attach_pusher_at(&self, pusher: Pusher, now: u64) {
        let unsent = {
            let mut state = self.state();
            state.pusher = Some(Arc::clone(&pusher));
            let unsent = std::mem::take(&mut state.unsent);
            let questions = &state.questions;
            unsent
                .into_iter()
                .filter(|event| {
                    question_of(event)
                        .and_then(|d| questions.get(d))
                        .is_some_and(|q| !q.closed && now <= q.answerable_until_ms)
                })
                .collect::<Vec<_>>()
        };
        for event in unsent {
            pusher(event);
        }
    }

    /// `cu_approval`: holds the question and pushes it to the phones, unless the
    /// same digest is held already (then only `always` may narrow).
    pub fn ask(&self, request: Value, always: bool) -> Result<(), String> {
        self.ask_at(request, always, now_ms())
    }

    pub fn ask_at(&self, request: Value, always: bool, now_ms: u64) -> Result<(), String> {
        let (digest, until) = check_request(&request, now_ms)?;
        let pusher = {
            let mut state = self.state();
            state.questions.retain(|_, q| now_ms <= q.answerable_until_ms);
            if let Some(held) = state.questions.get_mut(&digest) {
                held.always &= always;
                return Ok(());
            }
            if state.questions.len() >= MAX_QUESTIONS {
                return Err("too many Computer Use questions wait".into());
            }
            state
                .questions
                .insert(digest.clone(), Question { always, answerable_until_ms: until, closed: false });
            let event = push_event(&request, &digest, always);
            match state.pusher.clone() {
                Some(pusher) => Some((pusher, event)),
                None => {
                    let State { questions, unsent, .. } = &mut *state;
                    unsent.retain(|e| question_of(e).is_some_and(|d| questions.contains_key(d)));
                    unsent.push(event);
                    None
                }
            }
        };
        if let Some((pusher, event)) = pusher {
            pusher(event);
        }
        Ok(())
    }

    /// `cu_approval_done`: the question is over; a later answer is `not_pending`.
    pub fn done(&self, digest: &str) {
        let mut state = self.state();
        if let Some(question) = state.questions.get_mut(digest) {
            question.closed = true;
        }
        state.unsent.retain(|event| question_of(event) != Some(digest));
    }

    /// Whether `digest` waits for an answer at `now_ms`.
    pub fn is_pending(&self, digest: &str, now_ms: u64) -> bool {
        self.state().questions.get(digest).is_some_and(|q| !q.closed && now_ms <= q.answerable_until_ms)
    }

    /// Checks `phone`'s answer; when it counts, closes the question and tells the app.
    pub fn answer(&self, phone: &str, answer: &Answer) -> Result<(), Refusal> {
        self.answer_at(phone, answer, now_ms())
    }

    pub fn answer_at(&self, phone: &str, answer: &Answer, now_ms: u64) -> Result<(), Refusal> {
        let now = now_ms / 1000;
        let trust = self.trust.borrow().clone();
        let device = trust
            .as_ref()
            .and_then(|trust| {
                let device = trust.devices.iter().find(|d| d.id == phone)?;
                let denied =
                    trust.denied.iter().any(|d| d.id == phone && d.identity_key == device.identity_key);
                (!denied).then(|| device.clone())
            })
            .ok_or(Refusal::NotPaired)?;
        let event = {
            let mut state = self.state();
            let question = state
                .questions
                .get_mut(&answer.digest)
                .filter(|q| !q.closed && now_ms <= q.answerable_until_ms)
                .ok_or(Refusal::NotPending)?;
            let decision = Decision::parse(&answer.decision)
                .ok_or_else(|| Refusal::Refused("decision is once, session, always or deny".into()))?;
            if decision == Decision::Always && !question.always {
                return Err(Refusal::Refused("this question does not offer Always Allow".into()));
            }
            if answer.expires_at < now || answer.expires_at > now.saturating_add(MAX_LIFETIME) {
                return Err(Refusal::Expired);
            }
            let signature = match decision {
                // Narrowing needs no proof.
                Decision::Deny => None,
                _ => {
                    let signature = answer.signature.as_deref().ok_or(Refusal::BadSignature)?;
                    let signed = message(phone, &answer.digest, decision.as_str(), answer.expires_at);
                    if device.approval_key.is_empty()
                        || !crate::pairing::verify(&device.approval_key, &signed, signature)
                    {
                        return Err(Refusal::BadSignature);
                    }
                    Some(signature.to_ascii_lowercase())
                }
            };
            question.closed = true;
            Event::CuApprovalAnswer {
                phone_device_id: phone.to_owned(),
                digest: answer.digest.clone(),
                decision: decision.as_str().to_owned(),
                expires_at: answer.expires_at,
                signature,
            }
        };
        (self.emit)(event);
        Ok(())
    }

    /// A phone's `cu-approval-answer` line (already through the daemon policy):
    /// hostd's v12 response line.
    pub fn answer_line(&self, phone: &str, line: &[u8]) -> String {
        self.answer_line_at(phone, line, now_ms())
    }

    pub fn answer_line_at(&self, phone: &str, line: &[u8], now_ms: u64) -> String {
        let request: Value = serde_json::from_slice(line).unwrap_or_default();
        let id = request.get("id");
        let outcome = parse_link_answer(&request).and_then(|answer| self.answer_at(phone, &answer, now_ms));
        match outcome {
            Ok(()) => serde_json::json!({"id": id.cloned().unwrap_or(Value::Null), "ok": true, "data": {}})
                .to_string(),
            Err(refusal) => crate::policy::error_line(id, refusal.code(), &refusal.message()),
        }
    }

    /// A checked reply mailbox item of kind `computer_use` (`mailbox.rs`).
    pub fn apply_mailbox(&self, reply: &Reply) -> Result<(), Rejection> {
        self.apply_mailbox_at(reply, now_ms())
    }

    pub fn apply_mailbox_at(&self, reply: &Reply, now_ms: u64) -> Result<(), Rejection> {
        let answer = mailbox_answer(reply, now_ms).map_err(Refusal::rejection)?;
        self.answer_at(&reply.phone, &answer, now_ms).map_err(Refusal::rejection)
    }
}

/// The digest of the question a push carries.
fn question_of(event: &NotifyEvent) -> Option<&str> {
    event.computer_use.as_ref()?.pointer("/request/digest")?.as_str()
}

/// A request's digest and `answerable_until_ms`, when it is one the app may ask.
fn check_request(request: &Value, now_ms: u64) -> Result<(String, u64), String> {
    let Some(fields) = request.as_object() else { return Err("request is not an object".into()) };
    let held = fields.get("digest").and_then(Value::as_str).filter(|d| is_digest(d));
    let Some(held) = held else { return Err("request has no digest (64 lowercase hex)".into()) };
    if digest(fields).as_deref() != Some(held) {
        return Err("request digest does not match its canonical JSON".into());
    }
    let until = fields.get("answerable_until_ms").and_then(Value::as_u64).ok_or("no answerable_until_ms")?;
    if until < now_ms {
        return Err("the question is no longer answerable".into());
    }
    if request.pointer("/target/name").and_then(Value::as_str).is_none() {
        return Err("request has no target name".into());
    }
    let size = serde_json::json!({"request": request, "always": true}).to_string().len();
    if size > MAX_COMPUTER_USE_BYTES {
        return Err(format!("the question is {size} bytes; a push carries at most {MAX_COMPUTER_USE_BYTES}"));
    }
    Ok((held.to_owned(), until))
}

/// The notify event of a question: `kind: "computer_use"`, ids from the digest,
/// the labels, and the request as the app sent it (`computerUse`).
pub fn push_event(request: &Value, digest: &str, always: bool) -> NotifyEvent {
    let text = |pointer: &str, max: usize| {
        request
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(|t| crate::notify::label(t, max))
            .filter(|t| !t.is_empty())
    };
    let id = event_id(digest);
    NotifyEvent {
        event_id: id.clone(),
        kind: KIND.into(),
        permission_id: Some(id),
        agent: text("/agent", 60),
        workspace: text("/workspace", 120),
        title: text("/target/name", 120),
        state: Some("waiting".into()),
        computer_use: Some(serde_json::json!({"request": request, "always": always})),
        ..NotifyEvent::default()
    }
}

fn parse_link_answer(request: &Value) -> Result<Answer, Refusal> {
    let text = |k: &str| request.get(k).and_then(Value::as_str);
    let digest = text("digest").filter(|d| is_digest(d)).ok_or(Refusal::NotPending)?;
    let decision = text("decision").ok_or_else(|| Refusal::Refused("no decision".into()))?;
    let expires_at = request.get("expires_at").and_then(Value::as_u64).ok_or(Refusal::Expired)?;
    let signature = match request.get("signature") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(_) => return Err(Refusal::BadSignature),
    };
    Ok(Answer { digest: digest.to_owned(), decision: decision.to_owned(), expires_at, signature })
}

/// The answer a mailbox reply carries: `target.digest`, `action {type, optionId}`,
/// and for an allow `approval {approver, expiresAt, signature}`.
fn mailbox_answer(reply: &Reply, now_ms: u64) -> Result<Answer, Refusal> {
    let digest = reply.target.digest.clone().filter(|d| is_digest(d)).ok_or(Refusal::NotPending)?;
    let option = reply.option_id.as_deref().unwrap_or_default();
    let decision = match (&reply.action, option) {
        (ActionKind::Allow, "once" | "session" | "always") => option,
        (ActionKind::Deny, "deny" | "") => "deny",
        _ => return Err(Refusal::Refused("action and optionId do not agree".into())),
    };
    if decision == "deny" {
        // An unsigned deny: it lives as long as its mailbox item, at most MAX_LIFETIME.
        let expires_at = reply.expires_at.min(now_ms / 1000 + MAX_LIFETIME);
        return Ok(Answer { digest, decision: decision.into(), expires_at, signature: None });
    }
    let Some(Value::Object(approval)) = &reply.approval else { return Err(Refusal::BadSignature) };
    if approval.get("approver").and_then(Value::as_str) != Some(reply.phone.as_str()) {
        return Err(Refusal::Refused("the approver is not this iPhone".into()));
    }
    let expires_at = approval.get("expiresAt").and_then(Value::as_u64).ok_or(Refusal::Expired)?;
    let signature = approval.get("signature").and_then(Value::as_str).ok_or(Refusal::BadSignature)?;
    Ok(Answer { digest, decision: decision.into(), expires_at, signature: Some(signature.to_owned()) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mailbox::Target;
    use crate::pairing::{DeniedDevice, TrustedDevice};
    use ring::rand::SystemRandom;
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
    use serde_json::json;

    const NOW_MS: u64 = 1_793_400_010_000;
    const NOW: u64 = NOW_MS / 1000;

    fn vectors() -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../schemas/device-hub/test-vectors.json");
        serde_json::from_slice(&std::fs::read(&path).expect("schemas/device-hub/test-vectors.json"))
            .expect("test vectors are JSON")
    }

    fn request() -> Value {
        vectors()["approvalRequest"]["request"].clone()
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn key() -> (EcdsaKeyPair, String) {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        let public = hex(pair.public_key().as_ref());
        (pair, public)
    }

    fn sign(pair: &EcdsaKeyPair, phone: &str, digest: &str, decision: &str, expires: u64) -> String {
        hex(pair.sign(&SystemRandom::new(), &message(phone, digest, decision, expires)).unwrap().as_ref())
    }

    struct Rig {
        cu: ComputerUse,
        events: Arc<Mutex<Vec<Event>>>,
        pushes: Arc<Mutex<Vec<NotifyEvent>>>,
        pair: EcdsaKeyPair,
        digest: String,
    }

    fn rig_with(trust: impl FnOnce(String) -> DeviceTrust) -> Rig {
        let (pair, public) = key();
        let events: Arc<Mutex<Vec<Event>>> = Arc::default();
        let sink = Arc::clone(&events);
        let cu = ComputerUse::new(
            watch::channel(Some(trust(public))).1,
            Arc::new(move |event| sink.lock().unwrap().push(event)),
        );
        let pushes: Arc<Mutex<Vec<NotifyEvent>>> = Arc::default();
        let into = Arc::clone(&pushes);
        cu.attach_pusher_at(Arc::new(move |event| into.lock().unwrap().push(event)), NOW_MS);
        let digest = request()["digest"].as_str().unwrap().to_owned();
        Rig { cu, events, pushes, pair, digest }
    }

    fn paired(public: String) -> DeviceTrust {
        DeviceTrust {
            devices: vec![TrustedDevice {
                id: "phone-1".into(),
                identity_key: "04ab".into(),
                approval_key: public,
            }],
            denied: Vec::new(),
        }
    }

    fn rig() -> Rig {
        rig_with(paired)
    }

    fn answer(rig: &Rig, decision: &str, expires: u64) -> Answer {
        Answer {
            digest: rig.digest.clone(),
            decision: decision.into(),
            expires_at: expires,
            signature: (decision != "deny")
                .then(|| sign(&rig.pair, "phone-1", &rig.digest, decision, expires)),
        }
    }

    #[test]
    fn canonical_json_matches_the_shared_vectors() {
        let vectors = vectors();
        let cases = vectors["canonicalJson"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let text = canonical(&case["value"]).unwrap();
            assert_eq!(text, case["canonical"].as_str().unwrap());
            assert_eq!(crate::seal::sha256_hex(text.as_bytes()), case["sha256"].as_str().unwrap());
        }
        let request = request();
        assert_eq!(digest(request.as_object().unwrap()).as_deref(), request["digest"].as_str());
        assert_eq!(canonical(&json!({"a": 1.5})), None, "integers only");
        assert_eq!(canonical(&json!({"a": -1, "b": [2]})).as_deref(), Some(r#"{"a":-1,"b":[2]}"#));
    }

    #[test]
    fn the_signed_message_is_nul_joined() {
        assert_eq!(
            message("p", "d", "once", 1_793_400_120),
            [&b"cmux-cu-phone-approval-v1\0p\0d\0once\0"[..], b"1793400120"].concat()
        );
    }

    #[test]
    fn a_question_is_pushed_once_with_its_request() {
        let rig = rig();
        rig.cu.ask_at(request(), true, NOW_MS).unwrap();
        rig.cu.ask_at(request(), true, NOW_MS).unwrap();
        let pushes = rig.pushes.lock().unwrap().clone();
        assert_eq!(pushes.len(), 1, "the same digest is the same question");
        let body = serde_json::to_value(&pushes[0]).unwrap();
        let id = format!("cu-{}", &rig.digest[..32]);
        assert_eq!(body["kind"], "computer_use");
        assert_eq!(body["eventId"], id);
        assert_eq!(body["permissionId"], id);
        assert_eq!(body["agent"], "Claude");
        assert_eq!(body["workspace"], "api-server");
        assert_eq!(body["title"], "Text Editor \"β\" /tmp ☃", "the target's name, as a label");
        assert_eq!(body["state"], "waiting");
        assert_eq!(body["computerUse"], json!({"request": request(), "always": true}));
        // A re-send only narrows `always`.
        rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        let refused = rig.cu.answer_at("phone-1", &answer(&rig, "always", NOW + 120), NOW_MS);
        assert_eq!(refused.unwrap_err().code(), "refused");
    }

    #[test]
    fn a_request_must_carry_its_own_digest() {
        let rig = rig();
        let mut wrong = request();
        wrong["tool"] = json!("type_text");
        assert!(rig.cu.ask_at(wrong, false, NOW_MS).is_err());
        let mut none = request();
        none.as_object_mut().unwrap().remove("digest");
        assert!(rig.cu.ask_at(none, false, NOW_MS).is_err());
        assert!(rig.cu.ask_at(request(), false, 1_793_400_600_001).is_err(), "past answerable_until_ms");
        let mut large = request();
        large["target"]["name"] = json!("x".repeat(MAX_COMPUTER_USE_BYTES));
        let fields = large.as_object_mut().unwrap();
        let fixed = digest(fields).unwrap();
        fields.insert("digest".into(), json!(fixed));
        assert!(rig.cu.ask_at(large, false, NOW_MS).unwrap_err().contains("at most 2048"));
        assert!(rig.pushes.lock().unwrap().is_empty());
    }

    #[test]
    fn questions_asked_before_the_pusher_are_pushed_when_it_attaches() {
        let cu = ComputerUse::new(watch::channel(None).1, Arc::new(|_| {}));
        cu.ask_at(request(), false, NOW_MS).unwrap();
        let pushes: Arc<Mutex<Vec<NotifyEvent>>> = Arc::default();
        let into = Arc::clone(&pushes);
        cu.attach_pusher_at(Arc::new(move |event| into.lock().unwrap().push(event)), NOW_MS);
        assert_eq!(pushes.lock().unwrap().len(), 1);
        // One that expired before the pusher came is not pushed.
        let late = ComputerUse::new(watch::channel(None).1, Arc::new(|_| {}));
        late.ask_at(request(), false, NOW_MS).unwrap();
        let none: Arc<Mutex<Vec<NotifyEvent>>> = Arc::default();
        let into = Arc::clone(&none);
        late.attach_pusher_at(Arc::new(move |event| into.lock().unwrap().push(event)), 1_793_400_600_001);
        assert!(none.lock().unwrap().is_empty());
    }

    #[test]
    fn sealed_box_carries_the_computer_use_object() {
        let rig = rig();
        rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        let event = serde_json::to_value(&rig.pushes.lock().unwrap()[0]).unwrap();
        let identity = crate::pairing::MacIdentity::generate().unwrap();
        let push = crate::seal::random_secret().unwrap();
        let phones = vec![("phone-1".to_owned(), crate::seal::point_hex(&push.public_key()))];
        let body = crate::sealed_notify::sealed_body(&event, "mac-1", &identity, &phones, true, None);
        // Every phone has a push key: only routing ids in clear.
        assert_eq!(body["kind"], "computer_use");
        assert_eq!(body["eventId"], event["eventId"]);
        assert_eq!(body["permissionId"], event["permissionId"]);
        assert!(body.get("computerUse").is_none());
        assert!(body.get("title").is_none());
        let sealed = body["sealed"]["phone-1"]["box"].as_str().unwrap();
        let context = crate::seal::push_context("mac-1", "phone-1", event["eventId"].as_str().unwrap());
        let plain: Value =
            serde_json::from_slice(&crate::seal::open(&push, &context, sealed).unwrap()).unwrap();
        assert_eq!(plain["computerUse"], json!({"request": request(), "always": false}));
        assert_eq!(plain["kind"], "computer_use");
        assert_eq!(plain["title"], event["title"]);
    }

    #[test]
    fn valid_answers_are_told_to_the_app_once() {
        for decision in ["once", "session", "always", "deny"] {
            let rig = rig();
            rig.cu.ask_at(request(), true, NOW_MS).unwrap();
            let a = answer(&rig, decision, NOW + 120);
            assert_eq!(rig.cu.answer_at("phone-1", &a, NOW_MS), Ok(()), "{decision}");
            assert_eq!(
                rig.cu.answer_at("phone-1", &a, NOW_MS),
                Err(Refusal::NotPending),
                "{decision} replay"
            );
            let events = rig.events.lock().unwrap().clone();
            assert_eq!(events.len(), 1);
            let line = serde_json::to_value(&events[0]).unwrap();
            assert_eq!(line["type"], "cu_approval_answer");
            assert_eq!(line["phone_device_id"], "phone-1");
            assert_eq!(line["digest"], rig.digest.as_str());
            assert_eq!(line["decision"], decision);
            assert_eq!(line["expires_at"], NOW + 120);
            match decision {
                "deny" => assert!(line.get("signature").is_none()),
                _ => assert_eq!(line["signature"].as_str(), a.signature.as_deref()),
            }
            // A re-sent question after its answer is not asked again.
            rig.cu.ask_at(request(), true, NOW_MS).unwrap();
            assert_eq!(rig.pushes.lock().unwrap().len(), 1);
        }
    }

    #[test]
    fn the_answer_event_line_is_exact() {
        let line = serde_json::to_string(&Event::CuApprovalAnswer {
            phone_device_id: "p".into(),
            digest: "d".into(),
            decision: "once".into(),
            expires_at: 1_793_400_120,
            signature: Some("ab".into()),
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"cu_approval_answer","phone_device_id":"p","digest":"d","decision":"once","expires_at":1793400120,"signature":"ab"}"#
        );
        let deny = serde_json::to_string(&Event::CuApprovalAnswer {
            phone_device_id: "p".into(),
            digest: "d".into(),
            decision: "deny".into(),
            expires_at: 1,
            signature: None,
        })
        .unwrap();
        assert_eq!(
            deny,
            r#"{"type":"cu_approval_answer","phone_device_id":"p","digest":"d","decision":"deny","expires_at":1}"#
        );
    }

    #[test]
    fn each_refusal_has_its_reason() {
        let rig = rig();
        rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        let ok = answer(&rig, "once", NOW + 120);
        // Not paired: another phone, or a refused one.
        assert_eq!(rig.cu.answer_at("phone-2", &ok, NOW_MS), Err(Refusal::NotPaired));
        let denied = rig_with(|public| DeviceTrust {
            denied: vec![DeniedDevice { id: "phone-1".into(), identity_key: "04ab".into() }],
            ..paired(public)
        });
        denied.cu.ask_at(request(), false, NOW_MS).unwrap();
        let a = answer(&denied, "once", NOW + 120);
        assert_eq!(denied.cu.answer_at("phone-1", &a, NOW_MS), Err(Refusal::NotPaired));
        // Not pending: another digest, or past answerable_until_ms.
        let other = Answer { digest: "0".repeat(64), ..ok.clone() };
        assert_eq!(rig.cu.answer_at("phone-1", &other, NOW_MS), Err(Refusal::NotPending));
        assert_eq!(rig.cu.answer_at("phone-1", &ok, 1_793_400_600_001), Err(Refusal::NotPending));
        // Refused: an Always the question did not offer, an unknown decision.
        let always = answer(&rig, "always", NOW + 120);
        assert_eq!(rig.cu.answer_at("phone-1", &always, NOW_MS).unwrap_err().code(), "refused");
        let unknown = Answer { decision: "forever".into(), ..ok.clone() };
        assert_eq!(rig.cu.answer_at("phone-1", &unknown, NOW_MS).unwrap_err().code(), "refused");
        // Expired: in the past, or more than 300 s ahead.
        let late = answer(&rig, "once", NOW - 1);
        assert_eq!(rig.cu.answer_at("phone-1", &late, NOW_MS), Err(Refusal::Expired));
        let long = answer(&rig, "once", NOW + MAX_LIFETIME + 1);
        assert_eq!(rig.cu.answer_at("phone-1", &long, NOW_MS), Err(Refusal::Expired));
        // Bad signature: missing, another key, another decision, another phone's message.
        let unsigned = Answer { signature: None, ..ok.clone() };
        assert_eq!(rig.cu.answer_at("phone-1", &unsigned, NOW_MS), Err(Refusal::BadSignature));
        let (stranger, _) = key();
        let forged = Answer {
            signature: Some(sign(&stranger, "phone-1", &rig.digest, "once", NOW + 120)),
            ..ok.clone()
        };
        assert_eq!(rig.cu.answer_at("phone-1", &forged, NOW_MS), Err(Refusal::BadSignature));
        let swapped = Answer { decision: "session".into(), ..ok.clone() };
        assert_eq!(rig.cu.answer_at("phone-1", &swapped, NOW_MS), Err(Refusal::BadSignature));
        let moved = Answer {
            signature: Some(sign(&rig.pair, "phone-2", &rig.digest, "once", NOW + 120)),
            ..ok.clone()
        };
        assert_eq!(rig.cu.answer_at("phone-1", &moved, NOW_MS), Err(Refusal::BadSignature));
        assert!(rig.events.lock().unwrap().is_empty(), "no refused answer reaches the app");
        // The valid one still counts, once.
        assert_eq!(rig.cu.answer_at("phone-1", &ok, NOW_MS), Ok(()));
        assert_eq!(rig.cu.answer_at("phone-1", &ok, NOW_MS), Err(Refusal::NotPending));
    }

    #[test]
    fn done_drops_the_question() {
        let rig = rig();
        rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        assert!(rig.cu.is_pending(&rig.digest, NOW_MS));
        rig.cu.done(&rig.digest);
        assert!(!rig.cu.is_pending(&rig.digest, NOW_MS));
        assert_eq!(
            rig.cu.answer_at("phone-1", &answer(&rig, "once", NOW + 120), NOW_MS),
            Err(Refusal::NotPending)
        );
    }

    #[test]
    fn link_lines_are_answered_by_hostd() {
        let rig = rig();
        rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        let sig = sign(&rig.pair, "phone-1", &rig.digest, "session", NOW + 60);
        let line = json!({"cmd": "cu-approval-answer", "id": "c1", "digest": rig.digest, "decision": "session",
                          "expires_at": NOW + 60, "signature": sig});
        let answer: Value =
            serde_json::from_str(&rig.cu.answer_line_at("phone-1", line.to_string().as_bytes(), NOW_MS))
                .unwrap();
        assert_eq!(answer, json!({"id": "c1", "ok": true, "data": {}}));
        let again: Value =
            serde_json::from_str(&rig.cu.answer_line_at("phone-1", line.to_string().as_bytes(), NOW_MS))
                .unwrap();
        assert_eq!(again["ok"], false);
        assert_eq!(again["error_code"], "not_pending");
        assert_eq!(again["id"], "c1");
        let other = rig_with(paired);
        other.cu.ask_at(request(), false, NOW_MS).unwrap();
        let unpaired: Value =
            serde_json::from_str(&other.cu.answer_line_at("phone-9", line.to_string().as_bytes(), NOW_MS))
                .unwrap();
        assert_eq!(unpaired["error_code"], "not_paired");
        let deny = json!({"cmd": "cu-approval-answer", "id": "c2", "digest": other.digest, "decision": "deny",
                          "expires_at": NOW + 60});
        let denied: Value =
            serde_json::from_str(&other.cu.answer_line_at("phone-1", deny.to_string().as_bytes(), NOW_MS))
                .unwrap();
        assert_eq!(denied["ok"], true);
    }

    fn mailbox_reply(rig: &Rig, action: ActionKind, option: &str, approval: Option<Value>) -> Reply {
        Reply {
            id: "r1".into(),
            phone: "phone-1".into(),
            kind: "computer_use".into(),
            target: Target { digest: Some(rig.digest.clone()), ..Target::default() },
            action,
            option_id: Some(option.into()),
            answers: None,
            text: None,
            approval,
            nonce: "n0n0n0n0n0n0n0n0".into(),
            expires_at: NOW + 500,
        }
    }

    #[test]
    fn mailbox_answers_take_the_same_checks() {
        let rig = rig();
        rig.cu.ask_at(request(), true, NOW_MS).unwrap();
        let signed = |decision: &str| {
            json!({"approver": "phone-1", "expiresAt": NOW + 100,
                   "signature": sign(&rig.pair, "phone-1", &rig.digest, decision, NOW + 100)})
        };
        // The option and the action disagree; another approver; no approval.
        let mixed = mailbox_reply(&rig, ActionKind::Deny, "once", None);
        assert_eq!(rig.cu.apply_mailbox_at(&mixed, NOW_MS).unwrap_err().code(), "refused");
        let mut named = signed("always");
        named["approver"] = json!("phone-2");
        let other = mailbox_reply(&rig, ActionKind::Allow, "always", Some(named));
        assert_eq!(rig.cu.apply_mailbox_at(&other, NOW_MS).unwrap_err().code(), "refused");
        let bare = mailbox_reply(&rig, ActionKind::Allow, "always", None);
        assert_eq!(rig.cu.apply_mailbox_at(&bare, NOW_MS), Err(Rejection::BadSignature));
        let wrong = mailbox_reply(&rig, ActionKind::Allow, "always", Some(signed("once")));
        assert_eq!(rig.cu.apply_mailbox_at(&wrong, NOW_MS), Err(Rejection::BadSignature));
        // Valid always, then any second answer is not pending.
        let good = mailbox_reply(&rig, ActionKind::Allow, "always", Some(signed("always")));
        assert_eq!(rig.cu.apply_mailbox_at(&good, NOW_MS), Ok(()));
        assert_eq!(rig.cu.apply_mailbox_at(&good, NOW_MS), Err(Rejection::NotPending));
        let events = rig.events.lock().unwrap().clone();
        assert!(matches!(&events[..], [Event::CuApprovalAnswer { decision, .. }] if decision == "always"));
        // An unsigned deny lives at most MAX_LIFETIME.
        let deny_rig = rig_with(paired);
        deny_rig.cu.ask_at(request(), false, NOW_MS).unwrap();
        let deny = mailbox_reply(&deny_rig, ActionKind::Deny, "deny", None);
        assert_eq!(deny_rig.cu.apply_mailbox_at(&deny, NOW_MS), Ok(()));
        let events = deny_rig.events.lock().unwrap().clone();
        assert!(matches!(&events[..], [Event::CuApprovalAnswer { expires_at, signature: None, .. }]
            if *expires_at == NOW + MAX_LIFETIME));
    }
}
