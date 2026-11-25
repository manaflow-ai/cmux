//! Relay-held sends for the app (RFD 0142 R8, `cmux_mobile_link::hold_route`): a send while the Mac is not
//! joined to the session's relay is held there and answered in one relay RTT. Off unless the app calls
//! [`set_relay_hold_enabled`]; [`LinkHandle::relay_hold`](crate::LinkHandle::relay_hold) is `None` then, and on
//! any link that is not a WireGuard session.
//!
//! The item is the store-and-forward one (`mailbox_build`'s `sealed`), under the same id on every route: on
//! `Refused` or `Unanswered` the app posts the same item to the mailbox (or sends it on the next link), and
//! the Mac applies an id once whatever carried it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use cmux_mobile_link::hold_route::{HoldOutcome, HoldRoute};
use cmux_mobile_link::relay_hold::RefusedCode;

static ENABLED: AtomicBool = AtomicBool::new(false);

/// Turn relay-held sends on or off for links made from now on (default off).
#[uniffi::export]
pub fn set_relay_hold_enabled(on: bool) {
    ENABLED.store(on, Ordering::Relaxed);
}

pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RelayHoldOutcome {
    /// The relay holds it; `ms` after the first write.
    Accepted { ms: u64 },
    /// The Mac has it already.
    Delivered,
    /// The relay will not hold it (`off`, `bad`, `full`): route the same item another way.
    Refused { code: String },
    /// No relay socket now, or no answer in time: route the same item another way.
    Unanswered,
}

impl From<HoldOutcome> for RelayHoldOutcome {
    fn from(outcome: HoldOutcome) -> Self {
        match outcome {
            HoldOutcome::Accepted { ms } => Self::Accepted { ms },
            HoldOutcome::Delivered => Self::Delivered,
            HoldOutcome::Refused(code) => Self::Refused {
                code: match code {
                    RefusedCode::Off => "off",
                    RefusedCode::Bad => "bad",
                    RefusedCode::Full => "full",
                }
                .into(),
            },
            HoldOutcome::Unanswered => Self::Unanswered,
        }
    }
}

/// One link's relay-held send route.
#[derive(uniffi::Object)]
pub struct RelayHoldRoute {
    route: std::sync::Arc<HoldRoute>,
}

impl RelayHoldRoute {
    pub(crate) fn new(route: HoldRoute) -> Self {
        Self { route: std::sync::Arc::new(route) }
    }
}

#[uniffi::export]
impl RelayHoldRoute {
    /// Hold `sealed` under `id` and wait up to `wait_ms` for the relay.
    pub async fn send(&self, id: String, sealed: String, wait_ms: u32) -> RelayHoldOutcome {
        let route = std::sync::Arc::clone(&self.route);
        let wait = Duration::from_millis(u64::from(wait_ms));
        crate::on_runtime(async move { route.send(&id, &sealed, wait).await.into() }).await
    }
}
