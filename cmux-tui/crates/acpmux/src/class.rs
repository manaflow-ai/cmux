//! One class table for acpmux's queues (RFD 0182 S2, B9): the admission class a session's
//! model requests carry (the gateway priority header, `priority` in the hub) as a ranked enum,
//! and priority inheritance along acpmux wait edges (S8): a session waited on runs at the
//! highest class of the sessions waiting on it, until the wait ends.
//!
//! rt-mutex PI is the model (`Documentation/locking/rt-mutex-design.rst`): a low-priority task
//! holding what a high-priority one waits on runs at the waiter's priority until it lets go.
//! Here the "lock" is a lane's answer. A coordinator blocked in `wait` on a lane that the pool
//! puts to sleep early or starts as background waits behind every other lane (RFD 0182's
//! "will hit": "a coordinator waiting on a lane runs at the lane's class").

/// A session's class, lowest first, so `max` is the higher one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Class {
    /// `batch`: work nobody waits on.
    Batch,
    /// `background`: a lane, a helper, a script's chat.
    Lane,
    /// `coordinator`: a profile that names the gateway's coordinator class.
    Coordinator,
    /// `interactive`: a coordinator by role, a dictator or ask lane (`classify_role`).
    Interactive,
    /// A person's own chat (sent as `interactive`; a gateway may rank it higher itself).
    Person,
}

impl Class {
    /// The gateway priority value this class sends.
    pub fn wire(self) -> &'static str {
        match self {
            // fleet-only-ok: the existing priority module's own value; it is sent only through a gateway (`via_gateway`), so a person's own login sends nothing
            Class::Person | Class::Interactive => crate::subrouter_priority::INTERACTIVE,
            Class::Coordinator => "coordinator",
            // fleet-only-ok: the existing priority module's own value; it is sent only through a gateway (`via_gateway`), so a person's own login sends nothing
            Class::Lane => crate::subrouter_priority::BACKGROUND,
            Class::Batch => "batch",
        }
    }

    /// The class of a priority value (any case); `None` for one acpmux does not know.
    pub fn parse(value: &str) -> Option<Class> {
        match value.trim().to_ascii_lowercase().as_str() {
            "person" => Some(Class::Person),
            "interactive" => Some(Class::Interactive),
            "coordinator" => Some(Class::Coordinator),
            "background" | "lane" => Some(Class::Lane),
            "batch" => Some(Class::Batch),
            _ => None,
        }
    }
}

/// How many wait hops inheritance follows: a coordinator waits on a lane, which waits on its
/// helper, which waits on a sub-session. Deeper chains keep what they gathered so far.
pub const MAX_DEPTH: usize = 8;

/// The class `target` runs at: `own(target)` raised to the highest `own` of any session
/// waiting on it, directly or through a chain of waits ([`MAX_DEPTH`] hops). `waiters(id)`
/// lists the sessions waiting on `id` now; `own(id)` is `None` for one this host cannot class
/// (a peer's), which adds nothing but is still followed. A cycle (two sessions waiting on each
/// other) ends where it repeats.
pub fn inherited(
    target: &str,
    own: impl Fn(&str) -> Option<Class>,
    waiters: impl Fn(&str) -> Vec<String>,
) -> Option<Class> {
    let mut best = own(target);
    let mut seen = std::collections::HashSet::from([target.to_owned()]);
    let mut frontier = vec![target.to_owned()];
    for _ in 0..MAX_DEPTH {
        let mut next = Vec::new();
        for id in &frontier {
            for w in waiters(id) {
                if seen.insert(w.clone()) {
                    best = best.max(own(&w));
                    next.push(w);
                }
            }
        }
        if next.is_empty() {
            break;
        }
        frontier = next;
    }
    best
}

#[cfg(test)]
#[path = "class_tests.rs"]
mod tests;
