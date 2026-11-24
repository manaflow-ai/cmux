//! The phone's side of hostd's `pair-requests` service (cmux-mobile-host `pair_requests.rs`):
//! another device asking a linked Mac to pair is allowed from this phone, with no click on the
//! Mac (Leo, 2026-11-22: "ok surely we dont need to be bottled this hard by a click. and esp on a
//! single machine.").
//!
//! The decisions are here; Swift (`MacPairRequests`, CmuxMobileLive) opens the channel, shows a
//! card per request and calls back:
//!
//! - [`pair_requests_supported`]: only a Mac whose hostd lists `pair-requests-v1` is asked.
//! - [`pair_requests_parse`]: the `list` reply as cards, malformed rows dropped, at most
//!   [`MAX_CARDS`], each fingerprint shown in groups of four so the person can match it with the
//!   one the asking device shows.
//! - [`pair_requests_answer_args`]: the `answer` channel's args. The phone's channel args are a
//!   string map, so `allow` is `"true"` or `"false"` (hostd takes both forms).
//! - [`pair_requests_poll_delay_ms`]: when to list again. hostd pushes nothing when a request
//!   starts waiting, so the phone lists on link open and on foreground, every
//!   [`POLL_WHILE_SHOWN_MS`] while a card shows, every [`POLL_IDLE_MS`] for
//!   [`IDLE_WINDOW_MS`] after the last foreground, link open or shown card, then stops until the
//!   next one.

use std::collections::HashMap;

use serde_json::Value;

/// The hostd link service.
pub const SERVICE: &str = "pair-requests";
/// The capability a hostd with the service lists in its `version` reply.
pub const CAPABILITY: &str = "pair-requests-v1";
/// At most this many cards show (hostd lists at most 32).
pub const MAX_CARDS: usize = 8;
/// While a card shows: list again this often, so a request answered on the Mac, on another
/// device or timed out leaves the phone.
pub const POLL_WHILE_SHOWN_MS: u64 = 3_000;
/// With nothing waiting, while the app is in front: list this often...
pub const POLL_IDLE_MS: u64 = 10_000;
/// ...for this long after the last foreground, link open or shown card; then no more until the
/// next one.
pub const IDLE_WINDOW_MS: u64 = 5 * 60_000;

/// One waiting request as a card on the phone.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PairRequestCard {
    /// The asking device's id (what `answer` names).
    pub device_id: String,
    /// The name it asked under ("Probe iPhone"); its id when it gave none.
    pub name: String,
    /// `phone`, `mac` or `linux`.
    pub kind: String,
    /// The fingerprint hostd listed (lowercase hex, what `answer` sends back).
    pub fingerprint: String,
    /// The fingerprint for the person: groups of four ("1a2b 3c4d 5e6f 7a8b").
    pub fingerprint_shown: String,
    /// How long it has waited, in whole seconds.
    pub waited_seconds: u64,
}

/// Whether a Mac whose hostd lists `capabilities` serves `pair-requests`.
#[uniffi::export]
pub fn pair_requests_supported(capabilities: Vec<String>) -> bool {
    capabilities.iter().any(|c| c == CAPABILITY)
}

/// The service name, for Swift.
#[uniffi::export]
pub fn pair_requests_service() -> String {
    SERVICE.to_owned()
}

/// The `list` channel's args.
#[uniffi::export]
pub fn pair_requests_list_args() -> HashMap<String, String> {
    HashMap::from([("action".to_owned(), "list".to_owned())])
}

/// The cards of a `list` reply: `{"requests":[{"deviceId","name","kind","fingerprint","waitingMs"}]}`.
/// A row without a device id or with a fingerprint that is not 8 to 64 hex digits is dropped
/// (hostd could not take an answer to it); anything unreadable gives no cards.
#[uniffi::export]
pub fn pair_requests_parse(reply: String) -> Vec<PairRequestCard> {
    let Ok(value) = serde_json::from_str::<Value>(&reply) else { return Vec::new() };
    let Some(rows) = value.get("requests").and_then(Value::as_array) else { return Vec::new() };
    let mut cards: Vec<PairRequestCard> = Vec::new();
    for row in rows {
        let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or_default().trim();
        let device_id = text("deviceId");
        let fingerprint = text("fingerprint").to_ascii_lowercase();
        if device_id.is_empty()
            || !(8..=64).contains(&fingerprint.len())
            || !fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
        {
            continue;
        }
        // hostd lists oldest first; a device that asked again shows its newest keys once.
        cards.retain(|card| card.device_id != device_id);
        let name = text("name");
        cards.push(PairRequestCard {
            device_id: device_id.to_owned(),
            name: if name.is_empty() { device_id.to_owned() } else { name.chars().take(80).collect() },
            kind: match text("kind") {
                "" => "phone".to_owned(),
                kind => kind.to_owned(),
            },
            fingerprint_shown: grouped(&fingerprint),
            fingerprint,
            waited_seconds: row.get("waitingMs").and_then(Value::as_u64).unwrap_or(0) / 1000,
        });
    }
    cards.truncate(MAX_CARDS);
    cards
}

/// The `answer` channel's args for `card`.
#[uniffi::export]
pub fn pair_requests_answer_args(card: PairRequestCard, allow: bool) -> HashMap<String, String> {
    HashMap::from([
        ("action".to_owned(), "answer".to_owned()),
        ("deviceId".to_owned(), card.device_id),
        ("fingerprint".to_owned(), card.fingerprint),
        ("allow".to_owned(), allow.to_string()),
    ])
}

/// How long to wait before listing again: `shown` cards show now, and the last foreground, link
/// open or shown card was `quiet_ms` ago. `None`: stop (the next foreground or link open lists
/// again).
#[uniffi::export]
pub fn pair_requests_poll_delay_ms(shown: u32, quiet_ms: u64) -> Option<u64> {
    if shown > 0 {
        Some(POLL_WHILE_SHOWN_MS)
    } else if quiet_ms < IDLE_WINDOW_MS {
        Some(POLL_IDLE_MS)
    } else {
        None
    }
}

fn grouped(hex: &str) -> String {
    hex.as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(reply: &str) -> PairRequestCard {
        let mut cards = pair_requests_parse(reply.to_owned());
        assert_eq!(cards.len(), 1, "{reply}");
        cards.remove(0)
    }

    #[test]
    fn only_a_mac_listing_the_capability_is_asked() {
        assert!(pair_requests_supported(vec!["needs-you-v1".into(), "pair-requests-v1".into()]));
        assert!(!pair_requests_supported(vec!["needs-you-v1".into()]));
        assert!(!pair_requests_supported(Vec::new()));
    }

    #[test]
    fn a_listed_request_is_a_card_with_its_fingerprint_grouped() {
        let card = card(
            r#"{"requests":[{"deviceId":"probe","name":"Probe iPhone","kind":"phone","fingerprint":"1A2B3C4D5E6F7A8B","waitingMs":4200}]}"#,
        );
        assert_eq!(
            card,
            PairRequestCard {
                device_id: "probe".into(),
                name: "Probe iPhone".into(),
                kind: "phone".into(),
                fingerprint: "1a2b3c4d5e6f7a8b".into(),
                fingerprint_shown: "1a2b 3c4d 5e6f 7a8b".into(),
                waited_seconds: 4,
            }
        );
    }

    #[test]
    fn rows_hostd_could_not_answer_are_dropped() {
        let reply = r#"{"requests":[
            {"name":"no id","fingerprint":"1a2b3c4d5e6f7a8b"},
            {"deviceId":"short","fingerprint":"1a2b"},
            {"deviceId":"nothex","fingerprint":"zzzzzzzzzzzzzzzz"},
            {"deviceId":"ok","fingerprint":"1a2b3c4d5e6f7a8b"}
        ]}"#;
        let cards = pair_requests_parse(reply.into());
        assert_eq!(cards.iter().map(|c| c.device_id.as_str()).collect::<Vec<_>>(), ["ok"]);
        assert_eq!(cards[0].name, "ok", "no name: the id");
        assert_eq!(cards[0].kind, "phone");
    }

    #[test]
    fn unreadable_replies_give_no_cards() {
        for reply in ["", "nope", "{}", r#"{"requests":{}}"#, r#"{"error":"unpaired"}"#] {
            assert!(pair_requests_parse(reply.into()).is_empty(), "{reply}");
        }
    }

    #[test]
    fn a_device_that_asked_again_shows_once_with_its_newest_keys() {
        let reply = r#"{"requests":[
            {"deviceId":"probe","fingerprint":"aaaaaaaaaaaaaaaa"},
            {"deviceId":"probe","fingerprint":"bbbbbbbbbbbbbbbb"}
        ]}"#;
        let cards = pair_requests_parse(reply.into());
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].fingerprint, "bbbbbbbbbbbbbbbb");
    }

    #[test]
    fn at_most_max_cards_show() {
        let rows = (0..20)
            .map(|i| format!(r#"{{"deviceId":"d{i}","fingerprint":"1a2b3c4d5e6f7a8b"}}"#))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(pair_requests_parse(format!(r#"{{"requests":[{rows}]}}"#)).len(), MAX_CARDS);
    }

    #[test]
    fn answer_args_name_the_device_and_fingerprint_with_allow_as_text() {
        let card = card(r#"{"requests":[{"deviceId":"probe","fingerprint":"1a2b3c4d5e6f7a8b"}]}"#);
        let args = pair_requests_answer_args(card.clone(), true);
        assert_eq!(args["action"], "answer");
        assert_eq!(args["deviceId"], "probe");
        assert_eq!(args["fingerprint"], "1a2b3c4d5e6f7a8b");
        assert_eq!(args["allow"], "true");
        assert_eq!(pair_requests_answer_args(card, false)["allow"], "false");
        assert_eq!(pair_requests_list_args()["action"], "list");
    }

    #[test]
    fn polling_is_fast_while_a_card_shows_slow_while_recent_then_stops() {
        assert_eq!(pair_requests_poll_delay_ms(1, IDLE_WINDOW_MS * 10), Some(POLL_WHILE_SHOWN_MS));
        assert_eq!(pair_requests_poll_delay_ms(0, 0), Some(POLL_IDLE_MS));
        assert_eq!(pair_requests_poll_delay_ms(0, IDLE_WINDOW_MS - 1), Some(POLL_IDLE_MS));
        assert_eq!(pair_requests_poll_delay_ms(0, IDLE_WINDOW_MS), None);
    }
}
