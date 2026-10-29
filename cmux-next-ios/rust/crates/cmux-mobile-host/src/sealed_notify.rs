//! Sealed notification content (PROTOCOL.md "Sealed notify"). For each paired
//! phone that gave this Mac a push key (`push_keys.rs`), the notify body gets
//! `sealed[phone] = {box, sig}`: `box` seals the v2 `cmuxMobile` content to
//! that phone's push key, and `sig` is this Mac's identity signature over it.
//! The phone's service extension checks `sig` against the Mac key it pinned and
//! opens `box`; the backend and APNs see ids and ciphertext.
//!
//! When every paired phone has a push key, the body carries only the ids the
//! backend needs to route and coalesce (`eventId`, `kind`, and the session,
//! workspace, tab, permission, conversation and notification ids), never the
//! text: also when a box could not be made for one of them (that phone gets
//! the backend's fixed banner from the ids alone), and when this Mac's
//! identity key has not arrived yet (every phone gets the fixed banner).
//! A phone without a push key (an older app) still needs the plain content,
//! so then the body keeps it beside `sealed`, readable by the backend and
//! APNs (`verify/notifications-trust.md`, residual risks).
//!
//! For a question or permission the box also carries the prompt's acpmux
//! `decisionNonce` and `personInstance`, so the phone can sign an answer
//! without its link (the mailbox).

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Map, Value, json};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

use crate::config::AcpmuxTarget;
use crate::pairing::{DeviceTrust, MacIdentity};
use crate::push_keys::PushKeys;

/// The backend's limit for one box, in base64url characters (`MAX_SEALED_BOX`),
/// so the whole APNs payload stays under 4096 bytes.
pub const MAX_BOX_CHARS: usize = 3072;
/// The most plaintext one box holds: its base64url bytes less the version,
/// the ephemeral point, the nonce and the tag.
pub const MAX_BOX_PLAINTEXT: usize = MAX_BOX_CHARS * 3 / 4 - (1 + 65 + 12 + 16);

/// The sealed content cut to fit one box, in the backend's order for the
/// plain payload: the oldest last lines first, then option descriptions, a
/// shorter title and body, then the questions (the phone opens the app to
/// answer), then the last lines and the body altogether.
pub fn fit(content: &mut Map<String, Value>) {
    let size = |c: &Map<String, Value>| Value::Object(c.clone()).to_string().len();
    while size(content) > MAX_BOX_PLAINTEXT {
        let tail = content.get_mut("tail").and_then(Value::as_array_mut);
        if let Some(tail) = tail.filter(|t| t.len() > 1) {
            tail.remove(0);
            continue;
        }
        break;
    }
    if size(content) > MAX_BOX_PLAINTEXT
        && let Some(questions) = content.get_mut("questions").and_then(Value::as_array_mut)
    {
        for option in questions
            .iter_mut()
            .filter_map(|q| q.get_mut("options"))
            .filter_map(Value::as_array_mut)
            .flatten()
        {
            if let Some(option) = option.as_object_mut() {
                option.remove("description");
            }
        }
    }
    for (field, max) in [("title", 120), ("body", 160)] {
        if size(content) > MAX_BOX_PLAINTEXT
            && let Some(Value::String(text)) = content.get_mut(field)
        {
            *text = text.chars().take(max).collect();
        }
    }
    for field in ["questions", "tail", "body", "options"] {
        if size(content) > MAX_BOX_PLAINTEXT {
            content.remove(field);
        }
    }
}

/// Fields that route and coalesce a push: kept in clear.
pub const ROUTING_FIELDS: &[&str] = &[
    "eventId",
    "kind",
    "sessionId",
    "workspaceId",
    "tabId",
    "permissionId",
    "conversationId",
    "notificationId",
];

/// The notify body for `event` (the 0.13.0 JSON), sealed for `phones`
/// (`(phone, push key)`). `all_sealed`: every paired phone is among them, so
/// the content leaves only in boxes. `ask`: the prompt's decision nonce and
/// daemon run, for a question or permission.
pub fn sealed_body(
    event: &Value,
    mac: &str,
    identity: &MacIdentity,
    phones: &[(String, String)],
    all_sealed: bool,
    ask: Option<(String, String)>,
) -> Value {
    let Some(fields) = event.as_object() else { return event.clone() };
    if phones.is_empty() {
        return event.clone();
    }
    let event_id = fields.get("eventId").and_then(Value::as_str).unwrap_or_default();
    let mut content = fields.clone();
    content.insert("v".into(), json!(2));
    content.insert("mac".into(), json!(mac));
    // When it was posted: the phone drops the buttons of an old push replayed later.
    content.insert("postedAt".into(), json!(crate::mailbox::now()));
    if let Some((nonce, instance)) = ask {
        content.insert("decisionNonce".into(), json!(nonce));
        content.insert("personInstance".into(), json!(instance));
    }
    fit(&mut content);
    let plaintext = Value::Object(content).to_string();
    let mut sealed = Map::new();
    for (phone, push_key) in phones {
        let Ok(key) = crate::seal::public_key_hex(push_key) else { continue };
        let Ok(boxed) =
            crate::seal::seal(&key, &crate::seal::push_context(mac, phone, event_id), plaintext.as_bytes())
        else {
            continue;
        };
        // The backend refuses a box over its limit, and with it the whole push.
        if boxed.len() > MAX_BOX_CHARS {
            tracing::warn!(
                phone,
                len = boxed.len(),
                "a sealed push is over the box limit; that phone gets the fixed banner"
            );
            continue;
        }
        let Some(sig) = identity.sign(&crate::seal::push_signature_message(mac, phone, event_id, &boxed))
        else {
            continue;
        };
        sealed.insert(phone.clone(), json!({"box": boxed, "sig": sig}));
    }
    // Every paired phone has a key: the content never leaves in clear, even
    // when one box failed (that phone gets the fixed banner from the ids).
    let mut body: Map<String, Value> = if all_sealed {
        fields
            .iter()
            .filter(|(k, _)| ROUTING_FIELDS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    } else {
        fields.clone()
    };
    if !sealed.is_empty() {
        body.insert("sealed".into(), Value::Object(sealed));
    }
    Value::Object(body)
}

/// Only the fields that route and coalesce `event`.
pub fn routing_only(event: &Value) -> Value {
    let Some(fields) = event.as_object() else { return event.clone() };
    Value::Object(
        fields
            .iter()
            .filter(|(k, _)| ROUTING_FIELDS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect(),
    )
}

/// What the notifier needs to seal.
pub struct Sealer {
    pub mac: String,
    pub identity: watch::Receiver<Option<MacIdentity>>,
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    pub push_keys: Arc<PushKeys>,
    pub acpmux: AcpmuxTarget,
}

impl Sealer {
    /// The body to post for `event`: sealed when this Mac has its identity key
    /// and some paired phone a push key; else `event` as it is.
    pub async fn body(&self, event: Value) -> Value {
        let identity = self.identity.borrow().clone();
        let trust = self.trust.borrow().clone();
        let Some(trust) = trust else { return event };
        let phones = self.push_keys.for_paired(&trust);
        if phones.is_empty() {
            return event;
        }
        let all_sealed = phones.len() == trust.devices.len();
        let Some(identity) = identity else {
            // No key to seal with yet: never the content in clear for phones that expect boxes.
            return if all_sealed { routing_only(&event) } else { event };
        };
        let ask = match event.get("kind").and_then(Value::as_str) {
            Some("question" | "permission") => self.ask_secrets(&event).await,
            _ => None,
        };
        sealed_body(&event, &self.mac, &identity, &phones, all_sealed, ask)
    }

    /// The pending prompt's `decisionNonce` and `personInstance` (`_acpmux/info`).
    async fn ask_secrets(&self, event: &Value) -> Option<(String, String)> {
        let session = event.get("sessionId").and_then(Value::as_str)?;
        let permission = event.get("permissionId").and_then(Value::as_str)?;
        let ask = async {
            let mut socket = crate::services::connect_acpmux(&self.acpmux).await.ok()?;
            // acpmux answers nothing before `initialize` (PR B review, low).
            let initialize = json!({"jsonrpc": "2.0", "id": "cmux-mobile-seal-init", "method": "initialize",
                                    "params": {"protocolVersion": 1, "clientInfo": {"name": "cmux-mobile-host-seal", "version": "1"},
                                               "clientCapabilities": {}}});
            socket.send(Message::Text(initialize.to_string().into())).await.ok()?;
            let request = json!({"jsonrpc": "2.0", "id": "cmux-mobile-seal", "method": "_acpmux/info",
                                 "params": {"sessionId": session}});
            socket.send(Message::Text(request.to_string().into())).await.ok()?;
            while let Some(Ok(frame)) = socket.next().await {
                let Message::Text(text) = frame else { continue };
                let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
                if reply.get("id") != Some(&json!("cmux-mobile-seal")) {
                    continue;
                }
                return ask_from_info(reply.get("result")?, permission);
            }
            None
        };
        tokio::time::timeout(std::time::Duration::from_secs(3), ask).await.ok().flatten()
    }
}

/// `(decisionNonce, personInstance)` of `permission` in an `_acpmux/info` result.
pub fn ask_from_info(info: &Value, permission: &str) -> Option<(String, String)> {
    let pending = info
        .get("pending")?
        .as_array()?
        .iter()
        .find(|p| p.get("permissionId").and_then(Value::as_str) == Some(permission))?;
    let nonce = pending.get("decisionNonce").and_then(Value::as_str)?;
    let instance =
        pending.get("personInstance").or_else(|| info.get("personInstance")).and_then(Value::as_str)?;
    Some((nonce.to_owned(), instance.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap()
    }

    fn event() -> Value {
        json!({"eventId": "p-perm1", "kind": "question", "agent": "Claude", "place": "secret-repo",
               "sessionId": "s1", "permissionId": "perm/1", "title": "Deploy to prod?", "tail": ["sk-123"]})
    }

    #[test]
    fn content_leaves_only_in_boxes_the_phone_opens() {
        let v = vectors();
        let identity = MacIdentity::from_raw(
            v["macIdentityScalar"].as_str().unwrap(),
            v["macIdentityKey"].as_str().unwrap(),
        )
        .unwrap();
        let (mac, phone) = (v["mac"].as_str().unwrap(), v["phone"].as_str().unwrap());
        let phones = vec![(phone.to_owned(), v["phonePushKey"].as_str().unwrap().to_owned())];
        let body = sealed_body(&event(), mac, &identity, &phones, true, Some(("n1".into(), "run1".into())));
        let text = body.to_string();
        for secret in ["Deploy to prod", "sk-123", "secret-repo", "Claude"] {
            assert!(!text.contains(secret), "{secret} leaked: {text}");
        }
        assert_eq!(body["eventId"], "p-perm1");
        assert_eq!(body["sessionId"], "s1");
        let entry = &body["sealed"][phone];
        let boxed = entry["box"].as_str().unwrap();
        // The Mac's identity key signed it, for this phone and event.
        let message = crate::seal::push_signature_message(mac, phone, "p-perm1", boxed);
        assert!(crate::pairing::verify(
            v["macIdentityKey"].as_str().unwrap(),
            &message,
            entry["sig"].as_str().unwrap()
        ));
        // The phone's push key opens it, with the content and the ask's secrets.
        let push =
            p256::SecretKey::from_slice(&crate::seal::unhex(v["phonePushScalar"].as_str().unwrap()).unwrap())
                .unwrap();
        let opened: Value = serde_json::from_slice(
            &crate::seal::open(&push, &crate::seal::push_context(mac, phone, "p-perm1"), boxed).unwrap(),
        )
        .unwrap();
        assert_eq!(opened["title"], "Deploy to prod?");
        assert_eq!(opened["v"], 2);
        assert_eq!(opened["mac"], mac);
        assert_eq!(opened["decisionNonce"], "n1");
        assert_eq!(opened["personInstance"], "run1");
        // When it was posted, so the phone can drop an old one's buttons.
        assert!(opened["postedAt"].as_u64().is_some_and(|t| t > 1_700_000_000));
    }

    #[test]
    fn a_phone_without_a_push_key_keeps_the_plain_content() {
        let identity = MacIdentity::generate().unwrap();
        let push = crate::seal::random_secret().unwrap();
        let phones = vec![("p1".to_owned(), crate::seal::point_hex(&push.public_key()))];
        let body = sealed_body(&event(), "m", &identity, &phones, false, None);
        assert_eq!(body["title"], "Deploy to prod?");
        assert!(body["sealed"]["p1"]["box"].is_string());
        // No push keys at all: exactly the event.
        assert_eq!(sealed_body(&event(), "m", &identity, &[], true, None), event());
    }

    #[test]
    fn a_failed_box_never_puts_the_content_in_clear() {
        let identity = MacIdentity::generate().unwrap();
        let push = crate::seal::random_secret().unwrap();
        // The second phone's key is not a point: its box fails.
        let phones = vec![
            ("p1".to_owned(), crate::seal::point_hex(&push.public_key())),
            ("p2".to_owned(), "04zz".to_owned()),
        ];
        let body = sealed_body(&event(), "m", &identity, &phones, true, None);
        let text = body.to_string();
        assert!(!text.contains("Deploy to prod") && !text.contains("sk-123"), "{text}");
        assert!(body["sealed"]["p1"]["box"].is_string());
        assert!(body["sealed"].get("p2").is_none());
        // No identity key yet, every phone with a push key: routing ids only.
        assert_eq!(
            routing_only(&event()),
            json!({"eventId": "p-perm1", "kind": "question", "sessionId": "s1", "permissionId": "perm/1"})
        );
    }

    #[test]
    fn a_large_notification_fits_one_box() {
        let identity = MacIdentity::generate().unwrap();
        let push = crate::seal::random_secret().unwrap();
        let phone = "a2b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d";
        let phones = vec![(phone.to_owned(), crate::seal::point_hex(&push.public_key()))];
        let long = |n: usize| "é".repeat(n);
        let question = json!({"question": long(200), "header": long(30), "multiSelect": true, "allowsOther": true,
                              "options": (0..6).map(|i| json!({"label": format!("{i}{}", long(59)), "description": long(120)})).collect::<Vec<_>>()});
        let event = json!({"eventId": "p-big", "kind": "question", "agent": "Claude", "place": long(60),
                           "workspace": long(60), "sessionId": "s1", "permissionId": "p1", "title": long(200),
                           "body": long(400), "questions": [question.clone(), question.clone(), question.clone(), question],
                           "tail": (0..6).map(|i| format!("{i}{}", long(159))).collect::<Vec<_>>()});
        let body = sealed_body(&event, "m", &identity, &phones, true, Some(("n".into(), "run".into())));
        let boxed = body["sealed"][phone]["box"].as_str().unwrap();
        assert!(boxed.len() <= MAX_BOX_CHARS, "{}", boxed.len());
        let opened: Value = serde_json::from_slice(
            &crate::seal::open(&push, &crate::seal::push_context("m", phone, "p-big"), boxed).unwrap(),
        )
        .unwrap();
        // What routes and signs an answer always stays.
        for field in
            ["eventId", "kind", "sessionId", "permissionId", "decisionNonce", "personInstance", "title"]
        {
            assert!(opened.get(field).is_some(), "{field}");
        }
        // A small one keeps everything.
        let small = sealed_body(&super::tests::event(), "m", &identity, &phones, true, None);
        let boxed = small["sealed"][phone]["box"].as_str().unwrap();
        let opened: Value = serde_json::from_slice(
            &crate::seal::open(&push, &crate::seal::push_context("m", phone, "p-perm1"), boxed).unwrap(),
        )
        .unwrap();
        assert_eq!(opened["tail"], json!(["sk-123"]));
    }

    #[test]
    fn the_ask_secrets_come_from_the_pending_prompt() {
        let info = json!({"personInstance": "run-a", "pending": [
            {"permissionId": "p0", "decisionNonce": "x"},
            {"permissionId": "p1", "decisionNonce": "n1"}]});
        assert_eq!(ask_from_info(&info, "p1"), Some(("n1".into(), "run-a".into())));
        assert_eq!(ask_from_info(&info, "p9"), None);
    }
}
