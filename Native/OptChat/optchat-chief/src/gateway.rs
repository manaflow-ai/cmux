//! Shared model-gateway health for Chief turns and subagent starts.
//!
//! A refused connection is an outage of the endpoint, not an independent
//! failure of every session that happened to observe it. The health object is
//! shared by the host's turn and spawn paths so they use one threshold,
//! backoff clock and notice.

use std::collections::HashSet;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Refusals required before new work leaves the failing route.
pub const DEFAULT_THRESHOLD: u32 = 3;

/// A fallback that does not use the refused Claude gateway.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GatewayFallback {
    DirectAnthropic,
    Harness(String),
}

/// The route new work should use.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GatewayRoute {
    Primary,
    DirectAnthropic,
    Harness(String),
}

/// The shared result of observing one refusal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GatewayEvent {
    Observed { refusals: u32, backoff: Duration },
    EnteredFallback { refusals: u32, route: GatewayRoute },
    Fallback { refusals: u32, backoff: Duration },
    Ignored,
}

#[derive(Debug)]
struct State {
    refusals: u32,
    refused_sessions: HashSet<String>,
    fallback: bool,
    notice_taken: bool,
    next_retry: Option<Instant>,
}

/// Endpoint-scoped, cloneable health shared by turn and subagent workers.
#[derive(Clone)]
pub struct GatewayHealth {
    endpoint: String,
    threshold: u32,
    fallback: GatewayFallback,
    state: Arc<Mutex<State>>,
    probe: Option<Arc<dyn crate::auto_resume::Reachability>>,
}

impl fmt::Debug for GatewayHealth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GatewayHealth")
            .field("endpoint", &self.endpoint)
            .field("threshold", &self.threshold)
            .field("fallback", &self.fallback)
            .field("refusals", &self.refusals())
            .finish()
    }
}

impl PartialEq for GatewayHealth {
    fn eq(&self, other: &Self) -> bool {
        self.endpoint == other.endpoint
            && self.threshold == other.threshold
            && self.fallback == other.fallback
    }
}

impl Eq for GatewayHealth {}

impl GatewayHealth {
    pub fn new(endpoint: impl Into<String>, threshold: u32, fallback: GatewayFallback) -> Self {
        Self {
            endpoint: endpoint.into(),
            threshold: threshold.max(1),
            fallback,
            state: Arc::new(Mutex::new(State {
                refusals: 0,
                refused_sessions: HashSet::new(),
                fallback: false,
                notice_taken: false,
                next_retry: None,
            })),
            probe: None,
        }
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub fn with_probe(mut self, probe: Arc<dyn crate::auto_resume::Reachability>) -> Self {
        self.probe = Some(probe);
        self
    }

    /// A healthy endpoint returns new work to the primary route. The probe is
    /// only consulted while this endpoint is in fallback mode.
    pub fn refresh(&self) {
        let should_probe = self
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .fallback;
        if should_probe && self.probe.as_ref().is_some_and(|probe| probe.online()) {
            self.mark_healthy();
        }
    }

    /// Records a refused gateway connection and advances the one shared
    /// backoff. Non-refusal errors stay on their caller's normal path.
    pub fn record_refusal(&self, session: &str, error: &str) -> GatewayEvent {
        if !is_refusal(error) {
            return GatewayEvent::Ignored;
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.fallback {
            let backoff = shared_backoff(state.refusals);
            state.next_retry = Some(Instant::now() + backoff);
            return GatewayEvent::Fallback {
                refusals: state.refusals,
                backoff,
            };
        }
        if !session.is_empty() && !state.refused_sessions.insert(session.to_owned()) {
            let backoff = shared_backoff(state.refusals);
            state.next_retry = Some(Instant::now() + backoff);
            return GatewayEvent::Observed {
                refusals: state.refusals,
                backoff,
            };
        }
        state.refusals = state.refusals.saturating_add(1);
        let backoff = shared_backoff(state.refusals);
        state.next_retry = Some(Instant::now() + backoff);
        if state.refusals >= self.threshold {
            state.fallback = true;
            return GatewayEvent::EnteredFallback {
                refusals: state.refusals,
                route: self.route_locked(&state),
            };
        }
        GatewayEvent::Observed {
            refusals: state.refusals,
            backoff,
        }
    }

    /// Remaining shared wait before another primary-route attempt.
    pub fn retry_wait(&self) -> Duration {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .next_retry
            .map_or(Duration::ZERO, |at| {
                at.saturating_duration_since(Instant::now())
            })
    }

    pub fn route(&self) -> GatewayRoute {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        self.route_locked(&state)
    }

    /// Subagents cannot use the direct Messages API fallback, so they use a
    /// prepared Codex profile while the primary gateway is down.
    pub fn route_for_subagent(&self, codex_available: bool) -> GatewayRoute {
        match self.route() {
            GatewayRoute::DirectAnthropic if codex_available => {
                GatewayRoute::Harness("codex".into())
            }
            route => route,
        }
    }

    pub fn refusals(&self) -> u32 {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .refusals
    }

    /// Takes the one gateway-wide notice. Callers may post it to Chief; later
    /// session failures must remain quiet.
    pub fn take_notice(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if !state.fallback || state.notice_taken {
            return None;
        }
        state.notice_taken = true;
        Some(format!(
            "The model gateway at {} is refusing connections across sessions. New work is temporarily routed through {} while it recovers.",
            self.endpoint,
            self.route_name_locked(&state)
        ))
    }

    /// A successful probe or primary-route turn returns new work to the
    /// gateway and clears the outage counters and notice latch.
    pub fn mark_healthy(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.refusals = 0;
        state.refused_sessions.clear();
        state.fallback = false;
        state.notice_taken = false;
        state.next_retry = None;
    }

    fn route_locked(&self, state: &State) -> GatewayRoute {
        if !state.fallback {
            return GatewayRoute::Primary;
        }
        match &self.fallback {
            GatewayFallback::DirectAnthropic => GatewayRoute::DirectAnthropic,
            GatewayFallback::Harness(harness) => GatewayRoute::Harness(harness.clone()),
        }
    }

    fn route_name_locked(&self, state: &State) -> &'static str {
        match (&self.fallback, state.fallback) {
            (GatewayFallback::DirectAnthropic, true) => "the direct Anthropic route",
            (GatewayFallback::Harness(_), true) => "the Codex harness",
            (_, false) => "the primary route",
        }
    }
}

/// The error text that means the endpoint refused a connection. A dropped
/// stream or a 5xx is handled by the caller's ordinary transient retry path.
pub fn is_refusal(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("econnrefused") || lower.contains("connection refused")
}

fn shared_backoff(refusals: u32) -> Duration {
    Duration::from_secs(1u64 << refusals.max(1).saturating_sub(1).min(5))
}
