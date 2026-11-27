//! Which path one send takes (PROTOCOL.md "Store and forward", Phone): the link when it is up and
//! the Mac is present; the mailbox when the link is down or the Mac offline and the mailbox can
//! carry the item; else it fails as before. The same id rides either path, so a send that went
//! the link and then the mailbox (or the reverse, after a link drop) runs once on the Mac.
//!
//! A chat a Cloud machine holds (its Auto record's holder is `vm:`) takes the chat's Cloud inbox
//! instead, whatever the Mac's state (cmux#52931 `POST /v1/auto-sessions/:id/inbox`): the store
//! holds it while the machine resumes, and the machine runs it once with the id as its promptId.

/// Whether the Mac's signaling presence says it is reachable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Presence {
    Online,
    Offline,
    /// Not known yet: the link, if up, decides.
    Unknown,
}

/// Why a send went nowhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailReason {
    /// The link is out and the mailbox can't carry this item (an older Mac, or no trusted box key).
    NoRoute,
    /// The chat's Cloud inbox would mint another id for this one ([`inbox_id_ok`]), so a resend
    /// could run twice.
    BadInboxId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Link,
    Mailbox,
    /// Post `{id, text}` to the chat's Cloud inbox ([`inbox_post`]).
    CloudInbox,
    Fail(FailReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteInput {
    pub link_up: bool,
    pub presence: Presence,
    /// [`super::mailbox_available`] for this item.
    pub mailbox_available: bool,
    /// The chat is held by a Cloud machine: its Auto record's holder is `vm:<machine>`.
    pub cloud_holder: bool,
}

pub fn route(input: RouteInput) -> Route {
    if input.cloud_holder {
        Route::CloudInbox
    } else if input.link_up && input.presence != Presence::Offline {
        Route::Link
    } else if input.mailbox_available {
        Route::Mailbox
    } else {
        Route::Fail(FailReason::NoRoute)
    }
}

/// A decision with the id both paths share.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decision {
    pub id: String,
    pub route: Route,
}

/// Decides one send; the id is the item's (the composer's client message id).
pub fn decide(id: &str, input: RouteInput) -> Decision {
    let id = id.to_lowercase();
    let route = match route(input) {
        Route::CloudInbox if !inbox_id_ok(&id) => Route::Fail(FailReason::BadInboxId),
        r => r,
    };
    Decision { id, route }
}

/// The longest id the Cloud inbox and acpmux keep as is (cmux#52931 `MESSAGE_ID`, acpmux
/// `switch::message_id`).
pub const INBOX_ID_MAX: usize = 128;

/// Whether the Cloud inbox keeps `id` as the message's id and acpmux as its promptId: 1 to 128 of
/// `[A-Za-z0-9_.:-]`. Any other id gets a new one minted, and exactly once then breaks without
/// any error.
pub fn inbox_id_ok(id: &str) -> bool {
    (1..=INBOX_ID_MAX).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// The request for a [`Route::CloudInbox`] send: the path under the Cloud API and its JSON body.
/// The same id posted again answers the same message, so the caller retries it freely.
pub fn inbox_post(chat_id: &str, id: &str, text: &str) -> Option<(String, String)> {
    if !inbox_id_ok(id)
        || text.is_empty()
        || chat_id.is_empty()
        || !chat_id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    {
        return None;
    }
    let body = serde_json::json!({"id": id, "text": text}).to_string();
    Some((format!("/v1/auto-sessions/{chat_id}/inbox"), body))
}

/// The link attempt of `id` failed (the link dropped after the send): decide again as if it were
/// down, so the same id goes to the mailbox when it can.
pub fn link_failed(id: &str, mut input: RouteInput) -> Decision {
    input.link_up = false;
    decide(id, input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_truth_table() {
        use Presence::*;
        for link_up in [true, false] {
            for presence in [Online, Offline, Unknown] {
                for mailbox_available in [true, false] {
                    let got = route(RouteInput { link_up, presence, mailbox_available, cloud_holder: false });
                    let want = if link_up && presence != Offline {
                        Route::Link
                    } else if mailbox_available {
                        Route::Mailbox
                    } else {
                        Route::Fail(FailReason::NoRoute)
                    };
                    assert_eq!(got, want, "{link_up} {presence:?} {mailbox_available}");
                }
            }
        }
    }

    #[test]
    fn a_link_that_dropped_falls_to_the_mailbox_with_the_same_id() {
        let input = RouteInput {
            link_up: true,
            presence: Presence::Online,
            mailbox_available: true,
            cloud_holder: false,
        };
        let first = decide("0D9F5E2C-7B3A-4E61-8F20-5C4B3A291807", input);
        assert_eq!(first.route, Route::Link);
        let then = link_failed(&first.id, input);
        assert_eq!(then.route, Route::Mailbox);
        assert_eq!(then.id, first.id);
        let none = link_failed(&first.id, RouteInput { mailbox_available: false, ..input });
        assert_eq!(none.route, Route::Fail(FailReason::NoRoute));
    }

    #[test]
    fn a_cloud_held_chat_takes_its_inbox_whatever_the_mac_and_keeps_the_id() {
        use Presence::*;
        for link_up in [true, false] {
            for presence in [Online, Offline, Unknown] {
                for mailbox_available in [true, false] {
                    let input = RouteInput { link_up, presence, mailbox_available, cloud_holder: true };
                    let d = decide("0D9F5E2C-7B3A-4E61-8F20-5C4B3A291807", input);
                    assert_eq!(d.route, Route::CloudInbox);
                    assert_eq!(d.id, "0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807");
                }
            }
        }
        let input =
            RouteInput { link_up: false, presence: Offline, mailbox_available: false, cloud_holder: true };
        // An id the inbox would replace fails here instead of risking a second run.
        assert_eq!(decide("has space", input).route, Route::Fail(FailReason::BadInboxId));
        assert_eq!(decide(&"a".repeat(129), input).route, Route::Fail(FailReason::BadInboxId));
        assert_eq!(decide("", input).route, Route::Fail(FailReason::BadInboxId));
        assert_eq!(decide(&"a".repeat(128), input).route, Route::CloudInbox);
        assert_eq!(decide("s4-ab.cd:ef_09", input).route, Route::CloudInbox);
    }

    #[test]
    fn the_inbox_post_is_the_stores_request() {
        let (path, body) = inbox_post("chat_1", "s4-0a", "hi \"there\"").unwrap();
        assert_eq!(path, "/v1/auto-sessions/chat_1/inbox");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&body).unwrap(),
            serde_json::json!({"id": "s4-0a", "text": "hi \"there\""})
        );
        assert!(inbox_post("chat_1", "bad id", "x").is_none());
        assert!(inbox_post("chat_1", "ok", "").is_none());
        assert!(inbox_post("../x", "ok", "x").is_none());
        assert!(inbox_post("", "ok", "x").is_none());
    }
}
