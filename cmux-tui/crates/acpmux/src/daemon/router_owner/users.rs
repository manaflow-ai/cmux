//! Which kept agent hosts may use the running local router (cmux issue 23089).
//!
//! A router of another build is replaced at daemon start unless a kept
//! agent may still use it: that agent's harness started with the router's
//! loopback URL and a key only this router run knows (the keys live in its
//! memory, the port is random per run), so a new router would break its
//! model calls. A kept agent on any other route (its own subscription, an
//! API key, the subrouter) never talks to the router, and it must not pin
//! the router of an old build forever after an update.
//!
//! Each host says so itself: the daemon that spawned it decided from the
//! harness environment (`routes::names_local_router`) and the host keeps
//! the answer in its record (`HostRecord::uses_local_router`). A host of an
//! older build has no answer and counts as a user, so an unclear answer
//! keeps the router as before.

use crate::agent_host::sweep::OwnedHost;

/// The kept (not pooled) hosts in `hosts` that may use the local router.
pub(super) fn router_users(hosts: &[OwnedHost]) -> usize {
    hosts.iter().filter(|host| !host.pooled && host.uses_local_router != Some(false)).count()
}
