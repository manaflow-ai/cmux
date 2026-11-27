//! Which path one send takes (PROTOCOL.md "Store and forward", Phone): the link when it is up and
//! the Mac is present; the mailbox when the link is down or the Mac offline and the mailbox can
//! carry the item; else it fails as before. The same id rides either path, so a send that went
//! the link and then the mailbox (or the reverse, after a link drop) runs once on the Mac.

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Link,
    Mailbox,
    Fail(FailReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteInput {
    pub link_up: bool,
    pub presence: Presence,
    /// [`super::mailbox_available`] for this item.
    pub mailbox_available: bool,
}

pub fn route(input: RouteInput) -> Route {
    if input.link_up && input.presence != Presence::Offline {
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
    Decision { id: id.to_lowercase(), route: route(input) }
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
                    let got = route(RouteInput { link_up, presence, mailbox_available });
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
        let input = RouteInput { link_up: true, presence: Presence::Online, mailbox_available: true };
        let first = decide("0D9F5E2C-7B3A-4E61-8F20-5C4B3A291807", input);
        assert_eq!(first.route, Route::Link);
        let then = link_failed(&first.id, input);
        assert_eq!(then.route, Route::Mailbox);
        assert_eq!(then.id, first.id);
        let none = link_failed(&first.id, RouteInput { mailbox_available: false, ..input });
        assert_eq!(none.route, Route::Fail(FailReason::NoRoute));
    }
}
