//! A TURN allocation held for a device's next dial: while a link to a Mac is
//! up, the phone keeps one spare allocation for it, so a redial
//! ([`super::connect_after_held`], [`super::connect_held`]) takes it instead
//! of allocating on its path (an Allocate is two round trips to the TURN
//! server: the 401 challenge, then the authenticated request).
//!
//! The hold has at most one allocation, made or in hand. A dial takes it
//! whole: once taken it is the dial's own and the hold is empty until it is
//! armed again (the next link up). A dial that finds it still being made
//! waits for that one rather than starting a second. A dial that fails or is
//! dropped drops what it took, which deallocates (Refresh with LIFETIME 0).
//!
//! What it is bound to: a UDP allocation is the 5-tuple of its socket, so it
//! is only good on the network it was made on. A held allocation is not handed
//! out when the route's source address changed since it was made (the phone
//! left the Wi-Fi), when its stream to the server failed, or when it is older
//! than the hold's `max_age`; such an allocation is dropped and the dial
//! allocates as it would without a hold. A network change
//! ([`TurnHold::renew`]) drops the old allocation and makes one on the new
//! network. At `max_age` the hold makes a new one (turn-rs refreshes the
//! allocation on its own but does not say when a refresh fails).
//!
//! Released ([`TurnHold::release`], or the hold dropped): what it holds is
//! dropped and an allocation under way is aborted (one under way releases
//! what it opens). A dial already waiting on it still gets it. A dial
//! dropped while it waits leaves the allocation to the hold (it is still
//! the one spare), or drops it when the hold was released meanwhile.

use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use super::DialOptions;
use super::turn::TurnCarrier;
use super::wireguard::{EarlyTurn, primary_local_ip};
use crate::Timeline;

/// How long a held allocation is handed out before the hold makes a new one:
/// under the 10 min default TURN lifetime, so a hold whose refresh failed
/// unseen is replaced before the server would have dropped it.
pub const HOLD_MAX_AGE: Duration = Duration::from_secs(9 * 60);

type Waiter = Arc<Mutex<Option<oneshot::Sender<Option<TurnCarrier>>>>>;

#[derive(Default)]
enum Slot {
    #[default]
    Empty,
    /// An allocation under way; `waiter` is a dial waiting for it.
    Making {
        task: JoinHandle<()>,
        waiter: Waiter,
    },
    Ready {
        carrier: TurnCarrier,
        made: Instant,
        route: Option<IpAddr>,
    },
}

struct State {
    /// What the next allocation is made with; `None` once released.
    options: Option<DialOptions>,
    slot: Slot,
    /// Bumped by every new allocation and every release: a finished
    /// allocation of an older generation is dropped.
    generation: u64,
    /// The `max_age` re-make of the allocation in hand.
    timer: Option<JoinHandle<()>>,
    max_age: Duration,
}

/// One device's held TURN allocation. See the module docs.
pub struct TurnHold {
    state: Arc<Mutex<State>>,
}

fn lock(state: &Mutex<State>) -> std::sync::MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Default for TurnHold {
    fn default() -> Self {
        Self::new(HOLD_MAX_AGE)
    }
}

impl TurnHold {
    /// An empty hold that re-makes its allocation every `max_age`.
    pub fn new(max_age: Duration) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                options: None,
                slot: Slot::Empty,
                generation: 0,
                timer: None,
                max_age,
            })),
        }
    }

    /// Hold an allocation made with `options` (the dial's): one is made now
    /// unless the hold has a good one in hand or under way. Later
    /// allocations (`max_age`, [`Self::renew`]) use these options.
    pub fn arm(&self, options: &DialOptions) {
        let mut options = options.clone();
        // The hold's own allocations mark no dial's timeline.
        options.timeline = Timeline::new();
        let mut state = lock(&self.state);
        state.options = Some(options);
        let good = match &state.slot {
            Slot::Empty => false,
            Slot::Making { .. } => true,
            Slot::Ready { carrier, made, route } => fresh(carrier, *made, *route, state.max_age),
        };
        if !good {
            make(&self.state, &mut state);
        }
    }

    /// The network changed: the allocation in hand (or under way) is bound
    /// to the old one. Drop it and make one on the new network.
    pub fn renew(&self) {
        let mut state = lock(&self.state);
        if state.options.is_some() {
            make(&self.state, &mut state);
        }
    }

    /// Let go of the allocation (the link closed, the pool was torn down):
    /// nothing more is made until [`Self::arm`].
    pub fn release(&self) {
        let mut state = lock(&self.state);
        state.options = None;
        state.generation += 1;
        clear(&mut state);
    }

    /// Whether an allocation is in hand (tests, diagnostics).
    pub fn is_ready(&self) -> bool {
        matches!(lock(&self.state).slot, Slot::Ready { .. })
    }

    /// Whether the hold is armed: it has, makes or will make an allocation.
    pub fn is_armed(&self) -> bool {
        lock(&self.state).options.is_some()
    }

    /// The held allocation for a dial with `options`, as the dial's early
    /// allocation: the one in hand when it is still good, or the one under
    /// way (a dial waiting for it that gets none allocates itself). `None`
    /// when the hold has nothing to give (the dial allocates on its own).
    pub(crate) fn take(&self, options: &DialOptions) -> Option<EarlyTurn> {
        let mut state = lock(&self.state);
        match std::mem::take(&mut state.slot) {
            Slot::Empty => None,
            Slot::Ready { carrier, made, route } => {
                if let Some(timer) = state.timer.take() {
                    timer.abort();
                }
                if !fresh(&carrier, made, route, state.max_age) {
                    options.timeline.mark("turn_hold_stale");
                    return None;
                }
                options.timeline.mark("turn_held");
                Some(EarlyTurn::held(carrier))
            }
            Slot::Making { task, waiter } => {
                let mut cell = waiter.lock().unwrap_or_else(PoisonError::into_inner);
                if cell.is_some() {
                    // Another dial waits for this one already.
                    drop(cell);
                    state.slot = Slot::Making { task, waiter };
                    return None;
                }
                let (sender, receiver) = oneshot::channel();
                *cell = Some(sender);
                drop(cell);
                state.slot = Slot::Making { task, waiter };
                options.timeline.mark("turn_hold_waited");
                Some(EarlyTurn::awaiting(receiver, options))
            }
        }
    }
}

impl Drop for TurnHold {
    fn drop(&mut self) {
        self.release();
    }
}

/// Whether a held allocation may be handed out: its stream to the server
/// is alive, it is younger than `max_age`, and the route it was made on is
/// still the route (the source address toward the internet did not change).
fn fresh(carrier: &TurnCarrier, made: Instant, route: Option<IpAddr>, max_age: Duration) -> bool {
    !carrier.is_dead() && made.elapsed() < max_age && primary_local_ip() == route
}

/// Drop the slot: an allocation in hand is dropped (deallocated), one under
/// way aborted, unless a dial waits for it (it then goes to that dial).
fn clear(state: &mut State) {
    if let Some(timer) = state.timer.take() {
        timer.abort();
    }
    match std::mem::take(&mut state.slot) {
        Slot::Empty | Slot::Ready { .. } => {}
        Slot::Making { task, waiter } => {
            if waiter.lock().unwrap_or_else(PoisonError::into_inner).is_none() {
                task.abort();
            }
        }
    }
}

/// Replace the slot with a new allocation made with the hold's options.
fn make(shared: &Arc<Mutex<State>>, state: &mut State) {
    state.generation += 1;
    clear(state);
    let Some(options) = state.options.clone() else { return };
    let generation = state.generation;
    let weak = Arc::downgrade(shared);
    let waiter: Waiter = Arc::default();
    let delivered = Arc::clone(&waiter);
    let route = primary_local_ip();
    let task = tokio::spawn(async move {
        let carrier = TurnCarrier::allocate(&options).await;
        deliver(&weak, generation, &delivered, carrier, route);
    });
    state.slot = Slot::Making { task, waiter };
}

/// A finished allocation: to the dial waiting for it, else into the slot
/// when it is still the current generation, else dropped (released).
fn deliver(
    weak: &Weak<Mutex<State>>,
    generation: u64,
    waiter: &Waiter,
    carrier: Option<TurnCarrier>,
    route: Option<IpAddr>,
) {
    let shared = weak.upgrade();
    let mut state = shared.as_deref().map(lock);
    let current = state.as_ref().is_some_and(|state| state.generation == generation);
    let sender = waiter.lock().unwrap_or_else(PoisonError::into_inner).take();
    let carrier = match sender {
        Some(sender) => match sender.send(carrier) {
            Ok(()) => {
                if let (true, Some(state)) = (current, state.as_mut()) {
                    state.slot = Slot::Empty;
                }
                return;
            }
            Err(carrier) => carrier,
        },
        None => carrier,
    };
    let (Some(state), true, Some(carrier)) = (state.as_mut(), current, carrier) else {
        if let (Some(state), true) = (state.as_mut(), current) {
            state.slot = Slot::Empty;
        }
        return;
    };
    state.slot = Slot::Ready { carrier, made: Instant::now(), route };
    let weak = weak.clone();
    let max_age = state.max_age;
    state.timer = Some(tokio::spawn(async move {
        tokio::time::sleep(max_age).await;
        let Some(shared) = weak.upgrade() else { return };
        let mut state = lock(&shared);
        if state.generation == generation && matches!(state.slot, Slot::Ready { .. }) {
            // The re-make aborts this timer, which is past its last await.
            state.timer = None;
            make(&shared, &mut state);
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TestTurn;

    fn options(turn: &TestTurn) -> DialOptions {
        DialOptions {
            ice_servers: vec![turn.udp_only()],
            include_loopback: true,
            relay_only: true,
            timeout: Duration::from_secs(10),
            ..DialOptions::default()
        }
    }

    async fn until(what: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !what() {
            if Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        true
    }

    /// Armed twice, a hold makes one allocation; it is released with the hold.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn hold_makes_one_allocation_and_releases_it() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::default();
        hold.arm(&options(&turn));
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await, "the hold never allocated");
        hold.arm(&options(&turn));
        assert_eq!(turn.allocations(), 1);
        assert_eq!(turn.allocation_count(), 1, "re-arming a good hold allocated again");
        hold.release();
        assert!(until(|| turn.allocations() == 0).await, "release kept the allocation");
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await);
        drop(hold);
        assert!(until(|| turn.allocations() == 0).await, "a dropped hold kept its allocation");
    }

    /// A take hands over the allocation in hand without allocating, and the
    /// hold is then empty.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn take_hands_over_without_allocating() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::default();
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await);
        let dial = options(&turn);
        let mut early = hold.take(&dial).expect("held allocation");
        let carrier = early.carrier_for_test().await.expect("carrier");
        assert_eq!(turn.allocation_count(), 1, "the take allocated");
        assert!(hold.take(&dial).is_none(), "a taken hold gave a second allocation");
        assert!(dial.timeline.marks().iter().any(|(name, _)| name == "turn_held"));
        drop(carrier);
        assert!(until(|| turn.allocations() == 0).await, "a dropped taken allocation was kept");
    }

    /// A take while the allocation is under way waits for it; a release in
    /// the meantime still gives it to that dial.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn take_mid_allocation_waits_for_it_through_a_release() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::default();
        hold.arm(&options(&turn));
        let dial = options(&turn);
        let mut early = hold.take(&dial).expect("the allocation under way");
        assert!(hold.take(&dial).is_none(), "two dials waited for one allocation");
        hold.release();
        let carrier = early.carrier_for_test().await.expect("carrier");
        assert_eq!(turn.allocation_count(), 1);
        assert_eq!(turn.allocations(), 1);
        drop(carrier);
        assert!(until(|| turn.allocations() == 0).await);
    }

    /// A dial dropped while it waited for the allocation under way leaves
    /// that allocation to the hold (still one), and a release then drops it;
    /// dropped after a release, it releases the allocation itself.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn dropped_waiting_take_leaves_one_or_releases() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::default();
        hold.arm(&options(&turn));
        drop(hold.take(&options(&turn)).expect("the allocation under way"));
        assert!(until(|| hold.is_ready()).await, "the abandoned wait's allocation was lost");
        assert_eq!((turn.allocation_count(), turn.allocations()), (1, 1));
        hold.release();
        assert!(until(|| turn.allocations() == 0).await, "a release kept the allocation");
        hold.arm(&options(&turn));
        let early = hold.take(&options(&turn)).expect("the allocation under way");
        hold.release();
        drop(early);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            until(|| turn.allocations() == 0).await,
            "an abandoned wait after a release kept the allocation"
        );
        assert!(!hold.is_ready());
    }

    /// At `max_age` the hold makes a new allocation and drops the old one:
    /// one held throughout, and the new one is handed out.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn expiry_remakes_the_allocation() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::new(Duration::from_millis(300));
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await);
        assert!(until(|| turn.allocation_count() >= 2 && hold.is_ready()).await, "no re-make at max_age");
        assert!(until(|| turn.allocations() == 1).await, "{} held after a re-make", turn.allocations());
        let dial = options(&turn);
        let count = turn.allocation_count();
        let mut early = hold.take(&dial).expect("the re-made allocation");
        let carrier = early.carrier_for_test().await.expect("carrier");
        assert!(turn.allocation_count() - count <= 1, "the take allocated beyond the re-make");
        drop((carrier, hold));
        assert!(until(|| turn.allocations() == 0).await);
    }

    /// An allocation past `max_age` that the timer has not replaced yet is
    /// not handed out.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stale_allocation_is_not_handed_out() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::new(Duration::from_secs(600));
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await);
        lock(&hold.state).max_age = Duration::ZERO;
        let dial = options(&turn);
        assert!(hold.take(&dial).is_none(), "a stale allocation was handed out");
        assert!(dial.timeline.marks().iter().any(|(name, _)| name == "turn_hold_stale"));
        assert!(until(|| turn.allocations() == 0).await, "the stale allocation was kept");
    }

    /// A network change drops the old allocation and makes one on the new
    /// network: one held, two made.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn renew_replaces_the_allocation() {
        let turn = TestTurn::start().await;
        let hold = TurnHold::default();
        hold.arm(&options(&turn));
        assert!(until(|| hold.is_ready()).await);
        hold.renew();
        assert!(until(|| turn.allocation_count() == 2 && hold.is_ready()).await);
        assert!(until(|| turn.allocations() == 1).await, "{} held after renew", turn.allocations());
        hold.release();
        hold.renew();
        assert!(until(|| turn.allocations() == 0).await);
        assert_eq!(turn.allocation_count(), 2, "a released hold renewed");
    }
}
