//! One-request foreground catch-up (`cmux_mobile_core::catch_up::service`) for Swift: Rust
//! builds the `catch-up` channel's open args from the cursors the phone holds and reads the
//! one reply frame; Swift only opens the channel and hands the bytes over (Leo, 2026-11-24:
//! "the syncing can arguably happen in the background too, so deltas can be sipped and
//! maintained").
//!
//! One [`PhoneCatchUp`] per Mac. Its cursors are kept by the app ([`PhoneCatchUp::encode`],
//! read back with [`PhoneCatchUp::open`]), so the chat list's `listSeq`/`listEpoch` and each
//! chat's `lastSeq` survive a relaunch.
//!
//! With the Mac asleep the same surfaces come from the relay cache (`relay_*`, RFD 0142 R9,
//! `cmux_mobile_core::catch_up::relay`): the one relay cache client
//! (`cmux_mobile_link::relay_cache`) builds the call and opens the reply, core turns each delta
//! into a Mac answer and the same cursors move; Swift sends it over its own authenticated HTTPS
//! and applies each answer as a Mac reply's. Off unless the app's `relay.deltaCatchup` is on.

use std::sync::{Arc, Mutex, PoisonError};

use cmux_mobile_core::catch_up::relay::{self, Floors};
use cmux_mobile_core::catch_up::service::{self as core, Answer, Ask, Workspaces};
use cmux_mobile_core::catch_up::{Cursors, Wake};
use cmux_mobile_link::relay_cache;
use serde_json::Value;

/// The link service to open.
#[uniffi::export]
pub fn catch_up_service() -> String {
    core::SERVICE.to_string()
}

/// Whether a refused `catch-up` open (its close code) means the Mac has no such service, so
/// the app asks by today's separate calls.
#[uniffi::export]
pub fn catch_up_falls_back(code: String) -> bool {
    core::falls_back(&code)
}

/// A chat to bring up and the last event the phone holds of it (nil: the kept cursor's).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpChatAsk {
    pub session_id: String,
    pub last_seq: Option<u64>,
}

/// What a foreground catch-up asks for besides the kept cursors.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpAsk {
    /// The chat on screen, if any.
    pub on_screen_chat: Option<String>,
    /// The `known` object (JSON) of the tree the phone draws; nil when it draws none.
    pub known_json: Option<String>,
    /// What the phone's `daemon` line lists in `set-client-info`.
    pub capabilities: Vec<String>,
    /// Chats newest screenful first: the one on screen, then the recently opened ones.
    pub chats: Vec<CatchUpChatAsk>,
    /// Bytes the chats may answer with; 0 for the default (64 KiB).
    pub budget_bytes: u64,
}

/// What the reply said of the workspace tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CatchUpTree {
    /// The whole tree: `workspaces_json` is the `list-workspaces` reply's `data`.
    Whole,
    /// The tree the phone draws stands.
    Unchanged,
    /// Only the entries changed since a `since` cursor.
    Delta,
}

/// One chat's page.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpChatPage {
    pub session_id: String,
    /// The `_acpmux/attach` result as JSON.
    pub page_json: String,
    pub through_seq: Option<u64>,
    pub has_more: bool,
    pub older_before: Option<u64>,
}

/// Why a surface was not answered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpCut {
    /// `workspaces`, `chatList` or `chats:<id>`.
    pub name: String,
    pub reason: String,
}

/// The reply, after the kept cursors moved past what it answered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpAnswer {
    pub tree: Option<CatchUpTree>,
    pub workspaces_json: Option<String>,
    /// The `_acpmux/watch` result as JSON.
    pub chat_list_json: Option<String>,
    pub chats: Vec<CatchUpChatPage>,
    pub cut: Vec<CatchUpCut>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CatchUpError {
    #[error("{message}")]
    Reply { message: String },
}

/// One HTTPS call to the relay: `POST` `path` (under the relay's origin) with `body` (JSON).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RelayCall {
    pub path: String,
    pub body: String,
}

/// The phone's key the Mac seals relay deltas to: its push box key, a Secure Enclave key in
/// the app, so it only agrees (ECDH) and never leaves the enclave.
#[uniffi::export(with_foreign)]
pub trait RelayViewerKey: Send + Sync {
    /// The public key, SEC1 uncompressed (65 bytes).
    fn public_key(&self) -> Vec<u8>;
    /// The ECDH shared secret's x coordinate (32 bytes) with `peer` (SEC1).
    fn agree(&self, peer: Vec<u8>) -> Result<Vec<u8>, CatchUpError>;
}

pub(crate) struct ViewerAdapter {
    pub(crate) key: Arc<dyn RelayViewerKey>,
    pub(crate) public: p256::PublicKey,
}

impl cmux_relay_snapshot::Viewer for ViewerAdapter {
    fn public_key(&self) -> p256::PublicKey {
        self.public
    }

    fn agree(&self, peer: &p256::PublicKey) -> Result<[u8; 32], cmux_relay_snapshot::Error> {
        let shared = self
            .key
            .agree(peer.to_sec1_bytes().to_vec())
            .map_err(|_| cmux_relay_snapshot::Error::Unopened)?;
        shared.try_into().map_err(|_| cmux_relay_snapshot::Error::Unopened)
    }
}

/// An in-memory [`RelayViewerKey`] from a P-256 scalar (tests, and a phone without an enclave).
#[derive(Debug, uniffi::Object)]
pub struct RelaySoftwareKey(p256::SecretKey);

#[uniffi::export]
impl RelaySoftwareKey {
    #[uniffi::constructor]
    pub fn from_scalar(scalar: Vec<u8>) -> Result<Arc<Self>, CatchUpError> {
        p256::SecretKey::from_slice(&scalar)
            .map(|key| Arc::new(Self(key)))
            .map_err(|_| CatchUpError::Reply { message: "relay viewer key is not a P-256 scalar".into() })
    }
}

impl RelayViewerKey for RelaySoftwareKey {
    fn public_key(&self) -> Vec<u8> {
        self.0.public_key().to_sec1_bytes().to_vec()
    }

    fn agree(&self, peer: Vec<u8>) -> Result<Vec<u8>, CatchUpError> {
        let peer = p256::PublicKey::from_sec1_bytes(&peer)
            .map_err(|_| CatchUpError::Reply { message: "not a P-256 point".into() })?;
        Ok(cmux_relay_snapshot::Viewer::agree(&self.0, &peer)
            .map_err(|e| CatchUpError::Reply { message: e.to_string() })?
            .to_vec())
    }
}

/// What a relay catch-up brought.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RelayCatchUpAnswer {
    /// One per delta, in order: apply each as a Mac `catch-up` reply.
    pub answers: Vec<CatchUpAnswer>,
    /// Surfaces it did not bring up (`workspaces`, `chatList`, `chats:<id>`): ask the Mac.
    pub cut: Vec<CatchUpCut>,
    /// Send after applying: each drains the relay's log through what applied.
    pub acks: Vec<RelayCall>,
}

/// One Mac's catch-up cursors, and the relay positions they reached.
#[derive(Debug, uniffi::Object)]
pub struct PhoneCatchUp {
    cursors: Mutex<Cursors>,
    floors: Mutex<Floors>,
}

impl PhoneCatchUp {
    fn cursors(&self) -> std::sync::MutexGuard<'_, Cursors> {
        self.cursors.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn floors(&self) -> std::sync::MutexGuard<'_, Floors> {
        self.floors.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn take(&self, answer: &Answer, now: u64) -> CatchUpAnswer {
        self.cursors().apply_catch_up(answer, now);
        self.floors().set_from_mac(&answer.relay_heads);
        answer_record(answer)
    }
}

/// `answer` as the FFI record, moving nothing.
pub(crate) fn answer_record(answer: &Answer) -> CatchUpAnswer {
    let tree = answer.workspaces.as_ref().map(|tree| match tree {
        Workspaces::Tree(_) => CatchUpTree::Whole,
        Workspaces::Unchanged(_) => CatchUpTree::Unchanged,
        Workspaces::Delta(_) => CatchUpTree::Delta,
    });
    CatchUpAnswer {
        tree,
        workspaces_json: answer.workspaces.as_ref().map(|tree| tree.data().to_string()),
        chat_list_json: answer.chat_list.as_ref().map(Value::to_string),
        chats: answer
            .chats
            .iter()
            .map(|chat| CatchUpChatPage {
                session_id: chat.session_id.clone(),
                page_json: chat.page.to_string(),
                through_seq: chat.through_seq,
                has_more: chat.has_more,
                older_before: chat.older_before,
            })
            .collect(),
        cut: cuts(&answer.cut, &answer.cut_why),
    }
}

impl PhoneCatchUp {
    fn request(&self, wake: Wake, ask: CatchUpAsk) -> String {
        let mut core_ask = Ask::new(wake);
        core_ask.budget = ask.budget_bytes;
        core_ask.known = ask.known_json.and_then(|text| serde_json::from_str::<Value>(&text).ok());
        core_ask.capabilities = ask.capabilities;
        core_ask.chats = ask.chats.into_iter().map(|chat| (chat.session_id, chat.last_seq)).collect();
        core::request(&self.cursors(), &core_ask).to_string()
    }
}

fn cuts(names: &[String], why: &std::collections::BTreeMap<String, String>) -> Vec<CatchUpCut> {
    names
        .iter()
        .map(|name| CatchUpCut { name: name.clone(), reason: why.get(name).cloned().unwrap_or_default() })
        .collect()
}

#[uniffi::export]
impl PhoneCatchUp {
    /// The cursors `kept` holds ([`PhoneCatchUp::encode`]'s bytes); nothing readable starts
    /// from none, which asks for every surface whole.
    #[uniffi::constructor]
    pub fn open(kept: Option<Vec<u8>>) -> Arc<Self> {
        let cursors = kept.map(|bytes| Cursors::decode(&bytes)).unwrap_or_default();
        Arc::new(Self { cursors: Mutex::new(cursors), floors: Mutex::default() })
    }

    /// Reads back the relay positions [`PhoneCatchUp::relay_encode`] kept.
    pub fn relay_restore(&self, kept: Vec<u8>) {
        *self.floors() = Floors::decode(&kept);
    }

    /// The relay positions to keep beside [`PhoneCatchUp::encode`]'s bytes.
    pub fn relay_encode(&self) -> Vec<u8> {
        self.floors().encode()
    }

    /// The relay catch-up call to `source_device`'s cache as `viewer_device`: the workspaces,
    /// the chat list, then `chats` in the order given (on screen first, then recent; the budget
    /// cuts from the end). Nil when no surface has a relay position yet (the Mac has not said
    /// where its state reached).
    pub fn relay_request(
        &self,
        source_device: String,
        viewer_device: String,
        chats: Vec<String>,
        budget_bytes: u64,
    ) -> Option<RelayCall> {
        let mut surfaces = vec!["workspaces".to_string(), "chat-list".to_string()];
        surfaces.extend(chats.iter().map(|id| relay::chat_surface(id)));
        let asks = relay_cache::resume_asks(&relay::wanted(&self.floors(), &surfaces));
        if asks.is_empty() {
            return None;
        }
        let body = relay_cache::catch_up_body(&asks, relay::budget(budget_bytes)).ok()?;
        Some(RelayCall {
            path: relay_cache::path(&viewer_device, &source_device, "catch-up", &[]),
            body: body.to_string(),
        })
    }

    /// Reads the relay's reply: unseals with the phone's key (`viewer`) what the Mac's identity
    /// key (`source_public`, SEC1) sealed, moves the cursors of each delta applied and returns
    /// them in order.
    pub fn relay_apply(
        &self,
        source_device: String,
        viewer_device: String,
        reply: Vec<u8>,
        viewer: Arc<dyn RelayViewerKey>,
        source_public: Vec<u8>,
        now: u64,
    ) -> Result<RelayCatchUpAnswer, CatchUpError> {
        let bad = |message: String| CatchUpError::Reply { message };
        let public = p256::PublicKey::from_sec1_bytes(&viewer.public_key())
            .map_err(|_| bad("relay viewer key is not a P-256 point".into()))?;
        let viewer = ViewerAdapter { key: viewer, public };
        let source = p256::PublicKey::from_sec1_bytes(&source_public)
            .map_err(|_| bad("relay source key is not a P-256 point".into()))?;
        let reply = relay_cache::read_catch_up(&reply).map_err(|error| bad(error.to_string()))?;
        let mut floors = self.floors();
        let mut wanted: Vec<_> = reply
            .surfaces
            .iter()
            .filter_map(|answered| {
                Some((
                    answered.surface.clone(),
                    cmux_relay_snapshot::Floor::at(floors.get(&answered.surface)?),
                ))
            })
            .collect();
        let resume = relay_cache::apply_catch_up(reply, &source, &viewer, &mut wanted)
            .map_err(|error| bad(error.to_string()))?;
        let opened: Vec<relay::Opened<'_>> = resume
            .surfaces
            .iter()
            .map(|s| relay::Opened {
                surface: &s.surface,
                applied: &s.applied,
                stopped: s.stopped.as_ref(),
                head: s.head,
            })
            .collect();
        let got = relay::take(&mut floors, &resume.cut, &opened);
        drop(floors);
        let answers = got.answers.iter().map(|answer| self.take(answer, now)).collect();
        let acks = got
            .acks
            .iter()
            .map(|(surface, through)| RelayCall {
                path: relay_cache::path(&viewer_device, &source_device, "ack", &[("stream", surface)]),
                body: relay_cache::ack_body(*through).to_string(),
            })
            .collect();
        Ok(RelayCatchUpAnswer { answers, cut: cuts(&got.cut, &got.cut_why), acks })
    }

    /// The bytes to keep.
    pub fn encode(&self) -> Vec<u8> {
        self.cursors().encode()
    }

    /// The person opened a chat: it ranks first among the recent ones.
    pub fn opened_chat(&self, session_id: String, now: u64) {
        self.cursors().opened_chat(&session_id, now);
    }

    /// The `catch-up` channel's open args (a JSON object) for a foreground wake.
    pub fn foreground_request(&self, ask: CatchUpAsk) -> String {
        let wake = Wake::Foreground { chat: ask.on_screen_chat.clone(), terminal: None };
        self.request(wake, ask)
    }

    /// The args for a background wake: a push about `push_chat`, or a refresh when nil
    /// (`budget_bytes` 0 asks for the wake's budget).
    pub fn background_request(&self, ask: CatchUpAsk, push_chat: Option<String>) -> String {
        let wake = match push_chat {
            Some(chat) => Wake::Push { chat: Some(chat) },
            None => Wake::Refresh,
        };
        self.request(wake, ask)
    }

    /// Reads the reply frame and moves the cursors of what it answered; a cut surface keeps
    /// its cursor.
    pub fn apply(&self, reply: Vec<u8>, now: u64) -> Result<CatchUpAnswer, CatchUpError> {
        let answer =
            core::read(&reply).map_err(|error| CatchUpError::Reply { message: error.to_string() })?;
        Ok(self.take(&answer, now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_and_its_reply_round_trip_through_kept_cursors() {
        let catch_up = PhoneCatchUp::open(None);
        let args: Value = serde_json::from_str(&catch_up.foreground_request(CatchUpAsk {
            on_screen_chat: Some("a".into()),
            known_json: Some(r#"{"tree_revision":"r1"}"#.into()),
            capabilities: vec!["page-tabs-v1".into()],
            chats: vec![CatchUpChatAsk { session_id: "a".into(), last_seq: Some(4) }],
            budget_bytes: 0,
        }))
        .unwrap();
        assert_eq!(args["workspaces"]["known"]["tree_revision"], "r1");
        assert_eq!(args["chats"][0]["lastSeq"], 4);

        let reply = br#"{"v":1,"workspaces":{"unchanged":true},
            "chatList":{"listEpoch":"E","listSeq":9,"sessions":[]},
            "chats":[{"sessionId":"a","events":[],"lastSeq":6,"pageThrough":6,"hasMore":false}],
            "cut":["chats:b"],"cutWhy":{"chats:b":"budget"}}"#;
        let answer = catch_up.apply(reply.to_vec(), 1).unwrap();
        assert_eq!(answer.tree, Some(CatchUpTree::Unchanged));
        assert_eq!(answer.chats[0].through_seq, Some(6));
        assert_eq!(answer.cut, vec![CatchUpCut { name: "chats:b".into(), reason: "budget".into() }]);

        // The kept bytes carry the list cursor into the next request.
        let next = PhoneCatchUp::open(Some(catch_up.encode()));
        let args: Value = serde_json::from_str(&next.foreground_request(CatchUpAsk {
            on_screen_chat: None,
            known_json: None,
            capabilities: vec![],
            chats: vec![CatchUpChatAsk { session_id: "a".into(), last_seq: None }],
            budget_bytes: 0,
        }))
        .unwrap();
        assert_eq!(args["chatList"], serde_json::json!({"afterSeq": 9, "listEpoch": "E"}));
        assert_eq!(args["chats"][0]["lastSeq"], 6);
        assert!(catch_up.apply(b"nope".to_vec(), 2).is_err());
        assert!(catch_up_falls_back("unknown_service".into()));
        assert!(!catch_up_falls_back("timeout".into()));
    }

    #[test]
    fn a_relay_catch_up_resumes_where_the_mac_said_and_moves_the_same_cursors() {
        use base64::Engine as _;
        use cmux_relay_snapshot::{Position, delta, seal};
        let mac = p256::ecdsa::SigningKey::random(&mut rand_core::OsRng);
        let phone = p256::SecretKey::random(&mut rand_core::OsRng);
        let catch_up = PhoneCatchUp::open(None);
        // No relay position yet: nothing to ask.
        assert_eq!(catch_up.relay_request("mac".into(), "ph".into(), vec!["a".into()], 0), None);
        catch_up.apply(br#"{"v":1,"relay":{"chat/a":{"epoch":2,"seq":5}}}"#.to_vec(), 1).unwrap();
        let call = catch_up.relay_request("mac".into(), "ph".into(), vec!["a".into()], 0).unwrap();
        assert_eq!(call.path, "/v1/relay-cache/mac/catch-up?deviceId=ph");
        let body: Value = serde_json::from_str(&call.body).unwrap();
        assert_eq!(
            body["surfaces"],
            serde_json::json!([{"surface": "chat/a", "after": {"epoch": 2, "seq": 5}}])
        );

        let page = br#"{"sessionId":"a","events":[],"lastSeq":9,"pageThrough":9,"hasMore":false}"#;
        let sealed = seal(
            &mac,
            &phone.public_key(),
            &delta::delta_stream("chat/a"),
            Position { epoch: 2, seq: 6 },
            page,
        )
        .unwrap();
        let reply = serde_json::json!({"fromRelay": true, "cut": [], "surfaces": [{"surface": "chat/a",
            "sealed": [base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sealed)], "head": {"epoch": 2, "seq": 6}}]});
        let source = p256::PublicKey::from(mac.verifying_key()).to_sec1_bytes().to_vec();
        let got = catch_up
            .relay_apply(
                "mac".into(),
                "ph".into(),
                reply.to_string().into_bytes(),
                RelaySoftwareKey::from_scalar(phone.to_bytes().to_vec()).unwrap(),
                source.clone(),
                2,
            )
            .unwrap();
        assert_eq!(got.answers.len(), 1);
        assert_eq!(got.answers[0].chats[0].through_seq, Some(9));
        assert_eq!(
            got.acks,
            vec![RelayCall {
                path: "/v1/relay-cache/mac/ack?deviceId=ph&stream=chat%2Fa".into(),
                body: r#"{"through":{"epoch":2,"seq":6}}"#.into(),
            }]
        );
        // The same cursor a Mac reply moves, and the relay position kept.
        let next = PhoneCatchUp::open(Some(catch_up.encode()));
        next.relay_restore(catch_up.relay_encode());
        let args: Value = serde_json::from_str(&next.foreground_request(CatchUpAsk {
            on_screen_chat: None,
            known_json: None,
            capabilities: vec![],
            chats: vec![CatchUpChatAsk { session_id: "a".into(), last_seq: None }],
            budget_bytes: 0,
        }))
        .unwrap();
        assert_eq!(args["chats"][0]["lastSeq"], 9);
        let body: Value = serde_json::from_str(
            &next.relay_request("mac".into(), "ph".into(), vec!["a".into()], 0).unwrap().body,
        )
        .unwrap();
        assert_eq!(body["surfaces"][0]["after"]["seq"], 6);
        assert!(
            catch_up
                .relay_apply(
                    "mac".into(),
                    "ph".into(),
                    b"{}".to_vec(),
                    RelaySoftwareKey::from_scalar(phone.to_bytes().to_vec()).unwrap(),
                    source,
                    3
                )
                .is_err()
        );
        assert!(RelaySoftwareKey::from_scalar(vec![1; 3]).is_err());
    }
}
