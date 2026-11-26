//! First paint from the relay cache (RFD 0142 R2): on a cold open, before the Mac answers, the
//! phone reads the first screen the Mac left on the relay (`GET /v1/relay-cache/<mac>/snapshot`,
//! stream `<surface>/first`, at most 12 KiB, one round trip) and shows it as cached, "as of" the
//! time the relay stored it, until live state replaces it.
//!
//! Display only: a first screen is truncated (the newest rows, the newest events), so opening it
//! moves no catch-up cursor and no relay floor. It opens under the surface's relay floor, so a
//! first screen older than what the phone already holds is refused (`None`), never shown.
//! [`PhoneCatchUp::relay_cold_open_replaced`] says, by `(epoch, seq)`, when live or catch-up state
//! has reached past it. Swift only fetches the bytes, agrees ECDH with the push key and renders.
//! The app calls it behind the relay catch-up switch (`relay.deltaCatchup`, off by default).

use std::sync::Arc;

use cmux_mobile_core::catch_up::relay;
use cmux_mobile_link::relay_cache;
use cmux_relay_snapshot::{Error as SealError, Floor, Position};

use crate::catch_up::{
    CatchUpAnswer, CatchUpError, PhoneCatchUp, RelayViewerKey, ViewerAdapter, answer_record,
};

/// One cold-open fetch: `GET` `path` (under the relay's origin); its `x-cmux-cache-at` header
/// (milliseconds) is the "as of" time.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RelayColdOpenCall {
    /// `chat-list` or `chat/<sessionId>`.
    pub surface: String,
    pub path: String,
}

/// A first screen opened from the relay cache.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RelayColdOpen {
    pub surface: String,
    /// Apply as a `catch-up` answer would be, marked cached: `chat_list_json` for `chat-list`,
    /// one `chats` page for a chat.
    pub answer: CatchUpAnswer,
    /// When the relay stored it (ms since the epoch), from `x-cmux-cache-at`; `None` when the
    /// relay sent no time.
    pub as_of_ms: Option<u64>,
    /// Where the Mac's stream stood when it sealed it.
    pub epoch: u64,
    pub seq: u64,
}

fn bad(message: impl Into<String>) -> CatchUpError {
    CatchUpError::Reply { message: message.into() }
}

#[uniffi::export]
impl PhoneCatchUp {
    /// The first-screen fetches for a cold open: the chat list, then each of `chats` (the open
    /// one first), each once.
    pub fn relay_cold_open_calls(
        &self,
        source_device: String,
        viewer_device: String,
        chats: Vec<String>,
    ) -> Vec<RelayColdOpenCall> {
        let mut surfaces = vec![relay::CHAT_LIST.to_string()];
        for chat in chats {
            let surface = relay::chat_surface(&chat);
            if !surfaces.contains(&surface) {
                surfaces.push(surface);
            }
        }
        surfaces
            .into_iter()
            .take(relay::MAX_SURFACES)
            .map(|surface| RelayColdOpenCall {
                path: relay_cache::path(
                    &viewer_device,
                    &source_device,
                    "snapshot",
                    &[("stream", &relay_cache::first_screen_stream(&surface))],
                ),
                surface,
            })
            .collect()
    }

    /// Opens one fetched first screen: `envelope` (the reply's body) unsealed with the phone's key
    /// (`viewer`) as the Mac's identity key (`source_public`, SEC1) signed it for `surface`'s first
    /// screen. `None` when the phone already holds `surface` past it. Moves nothing.
    pub fn relay_cold_open(
        &self,
        surface: String,
        envelope: Vec<u8>,
        as_of_ms: Option<u64>,
        viewer: Arc<dyn RelayViewerKey>,
        source_public: Vec<u8>,
    ) -> Result<Option<RelayColdOpen>, CatchUpError> {
        let public = p256::PublicKey::from_sec1_bytes(&viewer.public_key())
            .map_err(|_| bad("relay viewer key is not a P-256 point"))?;
        let viewer = ViewerAdapter { key: viewer, public };
        let source = p256::PublicKey::from_sec1_bytes(&source_public)
            .map_err(|_| bad("relay source key is not a P-256 point"))?;
        // A copy of the surface's floor: a cold open is not state the phone holds.
        let mut floor = self.floors().get(&surface).map(Floor::at).unwrap_or_default();
        let stream = relay_cache::first_screen_stream(&surface);
        let opened = match floor.open(&viewer, &source, &stream, &envelope) {
            Ok(opened) => opened,
            Err(SealError::Stale { .. }) => return Ok(None),
            Err(error) => return Err(bad(format!("relay first screen {surface}: {error}"))),
        };
        let answer = relay::answer_of(&surface, &opened.plaintext)
            .ok_or_else(|| bad(format!("relay first screen {surface}: not its surface's answer")))?;
        Ok(Some(RelayColdOpen {
            surface,
            answer: answer_record(&answer),
            as_of_ms,
            epoch: opened.position.epoch,
            seq: opened.position.seq,
        }))
    }

    /// Whether live or catch-up state the phone holds for `surface` has reached a cold open at
    /// `(epoch, seq)`: then the cached rows and their "as of" give way.
    pub fn relay_cold_open_replaced(&self, surface: String, epoch: u64, seq: u64) -> bool {
        self.floors().get(&surface).is_some_and(|have| have >= Position { epoch, seq })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catch_up::RelaySoftwareKey;
    use cmux_relay_snapshot::seal;

    struct Keys {
        mac: p256::ecdsa::SigningKey,
        phone: p256::SecretKey,
    }

    impl Keys {
        fn new() -> Self {
            Self {
                mac: p256::ecdsa::SigningKey::random(&mut rand_core::OsRng),
                phone: p256::SecretKey::random(&mut rand_core::OsRng),
            }
        }

        fn seal(&self, stream: &str, epoch: u64, seq: u64, plaintext: &[u8]) -> Vec<u8> {
            seal(&self.mac, &self.phone.public_key(), stream, Position { epoch, seq }, plaintext).unwrap()
        }

        fn viewer(&self) -> Arc<dyn RelayViewerKey> {
            RelaySoftwareKey::from_scalar(self.phone.to_bytes().to_vec()).unwrap()
        }

        fn source(&self) -> Vec<u8> {
            p256::PublicKey::from(self.mac.verifying_key()).to_sec1_bytes().to_vec()
        }
    }

    #[test]
    fn cold_open_asks_the_chat_list_then_each_chat_first_screen_once() {
        let phone = PhoneCatchUp::open(None);
        let calls = phone.relay_cold_open_calls("mac".into(), "ph".into(), vec!["a".into(), "a".into()]);
        assert_eq!(
            calls,
            vec![
                RelayColdOpenCall {
                    surface: "chat-list".into(),
                    path: "/v1/relay-cache/mac/snapshot?deviceId=ph&stream=chat-list%2Ffirst".into(),
                },
                RelayColdOpenCall {
                    surface: "chat/a".into(),
                    path: "/v1/relay-cache/mac/snapshot?deviceId=ph&stream=chat%2Fa%2Ffirst".into(),
                },
            ]
        );
    }

    #[test]
    fn a_first_screen_opens_as_cached_with_its_time_and_moves_nothing() {
        let keys = Keys::new();
        let phone = PhoneCatchUp::open(None);
        let list = br#"{"sessions":[{"sessionId":"a","title":"A"}],"nextCursor":null}"#;
        let envelope = keys.seal("chat-list/first", 3, 7, list);
        let got = phone
            .relay_cold_open("chat-list".into(), envelope, Some(1_700), keys.viewer(), keys.source())
            .unwrap()
            .unwrap();
        assert_eq!((got.epoch, got.seq, got.as_of_ms), (3, 7, Some(1_700)));
        let shown: serde_json::Value =
            serde_json::from_str(got.answer.chat_list_json.as_deref().unwrap()).unwrap();
        assert_eq!(shown["sessions"][0]["sessionId"], "a");
        // No relay floor moved: nothing to resume from, and nothing has replaced it.
        assert_eq!(phone.relay_request("mac".into(), "ph".into(), vec![], 0), None);
        assert!(!phone.relay_cold_open_replaced("chat-list".into(), 3, 7));

        let page =
            br#"{"sessionId":"a","events":[],"lastSeq":9,"pageThrough":9,"hasMore":true,"olderBefore":4}"#;
        let chat = phone
            .relay_cold_open(
                "chat/a".into(),
                keys.seal("chat/a/first", 3, 8, page),
                None,
                keys.viewer(),
                keys.source(),
            )
            .unwrap()
            .unwrap();
        assert_eq!(chat.answer.chats.len(), 1);
        assert_eq!(chat.answer.chats[0].session_id, "a");
        assert_eq!(chat.as_of_ms, None);
    }

    #[test]
    fn live_state_past_a_first_screen_replaces_it_and_refuses_an_older_one() {
        let keys = Keys::new();
        let phone = PhoneCatchUp::open(None);
        // The Mac's own catch-up says the phone holds chat/a through (2, 5).
        phone.apply(br#"{"v":1,"relay":{"chat/a":{"epoch":2,"seq":5}}}"#.to_vec(), 1).unwrap();
        assert!(phone.relay_cold_open_replaced("chat/a".into(), 2, 4));
        assert!(phone.relay_cold_open_replaced("chat/a".into(), 2, 5));
        assert!(!phone.relay_cold_open_replaced("chat/a".into(), 2, 6));
        let page = br#"{"sessionId":"a","events":[],"lastSeq":3,"hasMore":false}"#;
        let older = keys.seal("chat/a/first", 2, 4, page);
        assert_eq!(
            phone.relay_cold_open("chat/a".into(), older, Some(1), keys.viewer(), keys.source()).unwrap(),
            None
        );
    }

    #[test]
    fn a_first_screen_for_another_surface_or_source_is_refused() {
        let keys = Keys::new();
        let phone = PhoneCatchUp::open(None);
        let page = br#"{"sessionId":"b","events":[],"lastSeq":3,"hasMore":false}"#;
        // Sealed for chat b's first screen, offered as chat a's: the signature names the stream.
        let envelope = keys.seal("chat/b/first", 1, 1, page);
        assert!(
            phone
                .relay_cold_open("chat/a".into(), envelope.clone(), None, keys.viewer(), keys.source())
                .is_err()
        );
        // Sealed as chat a's first screen, but holding chat b's page.
        let wrong = keys.seal("chat/a/first", 1, 1, page);
        assert!(phone.relay_cold_open("chat/a".into(), wrong, None, keys.viewer(), keys.source()).is_err());
        let other = Keys::new();
        assert!(
            phone.relay_cold_open("chat/b".into(), envelope, None, keys.viewer(), other.source()).is_err()
        );
    }
}
