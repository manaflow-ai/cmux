//! Why a WireGuard link found no path (PROTOCOL.md "When no path works").
//!
//! A dial records what each way to the peer did, in fallback order: plain
//! UDP, TURN (over UDP, then TLS on 443), then cmux's WebSocket relay. When
//! none of them carried a single authenticated datagram, the dial fails with
//! [`DialError::Blocked`] and that record, instead of a bare timeout, so the
//! app can say which part of the network is in the way and what to do
//! (another network, or which hosts IT must allow). The record is a few
//! words per path: hosts, an HTTP status, a TLS or socket error's text;
//! never a token, an address of the peer, or link data.

use std::sync::{Arc, Mutex, PoisonError};

use serde::Serialize;

use super::relay::RelayFailure;
use super::{DialError, TransportKind};

/// What each path did, in fallback order; `None`: not tried (yet).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PathFailures {
    /// Plain UDP: `blocked` (no STUN server answered: the network drops
    /// UDP) or `off` (debug: relay only, UDP blocked, relay via cmux only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub udp: Option<String>,
    /// TURN: `none_offered` (the service listed no TURN server),
    /// `no_allocation` (neither UDP nor TLS on 443 got one in time),
    /// `proxy_refused` (the system's proxy refused TURN over TLS: sign-in the
    /// link cannot do, a policy; [`Self::turn_detail`] says what) or `off`
    /// (debug: relay via cmux only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    /// The proxy's refusal, as a sentence, when `turn` is `proxy_refused`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_detail: Option<String>,
    /// The TURN server's host, for the person and for IT.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_host: Option<String>,
    /// cmux's WebSocket relay: `unavailable` (this side has none),
    /// `peer_cannot` (the peer's build has none), `refused`, `off` (`503
    /// relay_off`), `tls_rejected` (a certificate this side does not trust:
    /// a TLS-inspecting proxy), `unreachable`, `timeout`, `no_token`, or
    /// `peer_absent` (joined, but the peer never did: its network blocks
    /// the relay).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
    /// The relay's host (the Worker's).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_host: Option<String>,
    /// The HTTP status of a refused join (a proxy's own `403` included).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_status: Option<u16>,
    /// The refusal's code, or the TLS or socket error's text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_detail: Option<String>,
}

impl PathFailures {
    /// The record as one JSON object (the app reads it from the error).
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".into())
    }
}

impl std::fmt::Display for PathFailures {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut parts = Vec::new();
        if let Some(udp) = &self.udp {
            parts.push(format!("UDP {udp}"));
        }
        if let Some(turn) = &self.turn {
            let host = self.turn_host.as_deref().map(|host| format!(" ({host})")).unwrap_or_default();
            let detail = self.turn_detail.as_deref().map(|detail| format!(": {detail}")).unwrap_or_default();
            parts.push(format!("TURN{host} {}{detail}", turn.replace('_', " ")));
        }
        if let Some(relay) = &self.relay {
            let host = self.relay_host.as_deref().map(|host| format!(" ({host})")).unwrap_or_default();
            let status = self.relay_status.map(|status| format!(" {status}")).unwrap_or_default();
            let detail = self.relay_detail.as_deref().map(|detail| format!(": {detail}")).unwrap_or_default();
            parts.push(format!("cmux relay{host} {}{status}{detail}", relay.replace('_', " ")));
        }
        if parts.is_empty() {
            return f.write_str("nothing tried");
        }
        f.write_str(&parts.join("; "))
    }
}

#[derive(Debug, Default)]
struct State {
    failures: PathFailures,
    /// Something authenticated on some path: the network does not block
    /// the link, whatever else failed.
    reached: bool,
    /// The relay, the last way, failed while nothing else worked: the dial
    /// need not wait out its timeout.
    gave_up: bool,
}

/// One dial's record, shared by its clones of `DialOptions` and its tunnel.
#[derive(Clone, Default)]
pub struct Diagnosis {
    state: Arc<Mutex<State>>,
    gave_up: Arc<tokio::sync::Notify>,
}

impl std::fmt::Debug for Diagnosis {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Diagnosis").field(&self.snapshot()).finish()
    }
}

impl Diagnosis {
    fn with<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        f(&mut self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Plain UDP's outcome (`blocked`, `off`).
    pub fn udp(&self, outcome: &str) {
        self.with(|state| state.failures.udp = Some(outcome.to_owned()));
    }

    /// TURN's outcome (`none_offered`, `no_allocation`, `off`) and its host.
    pub fn turn(&self, outcome: &str, host: Option<String>) {
        self.with(|state| {
            state.failures.turn = Some(outcome.to_owned());
            state.failures.turn_host = host;
        });
    }

    /// The system's proxy refused TURN over TLS: `proxy_refused`, the
    /// proxy's sentence, and the TURN host.
    pub fn turn_refused_by_proxy(&self, detail: &str, host: Option<String>) {
        self.with(|state| {
            state.failures.turn = Some("proxy_refused".to_owned());
            state.failures.turn_detail = Some(detail.to_owned());
            state.failures.turn_host = host;
        });
    }

    /// Whether a proxy refused TURN over TLS on this dial.
    pub fn turn_refused(&self) -> bool {
        self.with(|state| state.failures.turn.as_deref() == Some("proxy_refused"))
    }

    /// The relay's outcome without a join (`unavailable`, `peer_cannot`,
    /// `peer_absent`).
    pub fn relay(&self, outcome: &str, host: Option<String>) {
        self.with(|state| {
            state.failures.relay = Some(outcome.to_owned());
            state.failures.relay_host = host;
            state.failures.relay_status = None;
            state.failures.relay_detail = None;
        });
    }

    /// A join that failed.
    pub fn relay_failed(&self, failure: &RelayFailure, host: String) {
        let (outcome, status, detail) = match failure {
            RelayFailure::NoToken => ("no_token", None, None),
            RelayFailure::Refused { status: 503, code } if code == "relay_off" => ("off", Some(503), None),
            RelayFailure::Refused { status, code } => {
                ("refused", Some(*status), (!code.is_empty()).then(|| code.clone()))
            }
            RelayFailure::TlsRejected { detail } => ("tls_rejected", None, Some(detail.clone())),
            RelayFailure::Unreachable { detail } => ("unreachable", None, Some(detail.clone())),
            RelayFailure::Timeout => ("timeout", None, None),
        };
        self.with(|state| {
            state.failures.relay = Some(outcome.to_owned());
            state.failures.relay_host = Some(host);
            state.failures.relay_status = status;
            // A few words, never a page of an error chain.
            state.failures.relay_detail = detail.map(|detail| detail.chars().take(120).collect());
        });
    }

    /// An authenticated datagram arrived: the network carries the link.
    pub fn reached(&self) {
        self.with(|state| state.reached = true);
    }

    /// Whether anything ever authenticated.
    pub fn has_reached(&self) -> bool {
        self.with(|state| state.reached)
    }

    /// The relay failed too and nothing else ever worked: end the dial now.
    pub fn give_up(&self) {
        let fire = self.with(|state| {
            let fire = !state.reached && !state.gave_up;
            state.gave_up |= fire;
            fire
        });
        if fire {
            self.gave_up.notify_waiters();
            self.gave_up.notify_one();
        }
    }

    /// Resolves once [`Self::give_up`] was called.
    pub async fn given_up(&self) {
        loop {
            let notified = self.gave_up.notified();
            if self.with(|state| state.gave_up) {
                return;
            }
            notified.await;
        }
    }

    pub fn snapshot(&self) -> PathFailures {
        self.with(|state| state.failures.clone())
    }

    /// The error for a dial or answer that ran out of time: [`DialError::Blocked`]
    /// when it was a WireGuard dial that never reached the peer and tried the
    /// relay (or had none), else [`DialError::Timeout`].
    pub fn timed_out(&self, kind: TransportKind) -> DialError {
        self.with(|state| {
            if kind == TransportKind::WireGuard && !state.reached && state.failures.relay.is_some() {
                DialError::Blocked(Box::new(state.failures.clone()))
            } else {
                DialError::Timeout
            }
        })
    }

    /// [`DialError::Blocked`] with the record now.
    pub fn blocked(&self) -> DialError {
        DialError::Blocked(Box::new(self.snapshot()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dial_that_never_reached_the_peer_says_why_each_path_failed() {
        let diagnosis = Diagnosis::default();
        diagnosis.udp("blocked");
        diagnosis.turn("no_allocation", Some("turn.cloudflare.com".into()));
        // Before the relay was tried it is still a plain timeout.
        assert!(matches!(diagnosis.timed_out(TransportKind::WireGuard), DialError::Timeout));
        diagnosis.relay_failed(
            &RelayFailure::TlsRejected { detail: "invalid peer certificate: UnknownIssuer".into() },
            "mobile-api.cmux.dev".into(),
        );
        let DialError::Blocked(failures) = diagnosis.timed_out(TransportKind::WireGuard) else {
            panic!("not blocked")
        };
        assert_eq!(failures.relay.as_deref(), Some("tls_rejected"));
        assert_eq!(
            failures.to_string(),
            "UDP blocked; TURN (turn.cloudflare.com) no allocation; cmux relay (mobile-api.cmux.dev) tls rejected: invalid peer certificate: UnknownIssuer"
        );
        let json: serde_json::Value = serde_json::from_str(&failures.to_json()).unwrap();
        assert_eq!(json["udp"], "blocked");
        assert_eq!(json["turnHost"], "turn.cloudflare.com");
        assert_eq!(json["relay"], "tls_rejected");
        assert!(json.get("relayStatus").is_none());
        // WebRTC never says blocked; a dial that reached the peer once never does.
        assert!(matches!(diagnosis.timed_out(TransportKind::WebRtc), DialError::Timeout));
        diagnosis.reached();
        assert!(matches!(diagnosis.timed_out(TransportKind::WireGuard), DialError::Timeout));
    }

    #[test]
    fn a_turned_off_relay_and_a_proxy_refusal_read_differently() {
        let diagnosis = Diagnosis::default();
        diagnosis.relay_failed(&RelayFailure::Refused { status: 503, code: "relay_off".into() }, "h".into());
        assert_eq!(diagnosis.snapshot().relay.as_deref(), Some("off"));
        diagnosis.relay_failed(&RelayFailure::Refused { status: 403, code: String::new() }, "h".into());
        let failures = diagnosis.snapshot();
        assert_eq!((failures.relay.as_deref(), failures.relay_status), (Some("refused"), Some(403)));
        assert_eq!(failures.relay_detail, None);
    }

    #[tokio::test]
    async fn giving_up_wakes_the_dial_once_and_never_after_the_peer_was_reached() {
        let diagnosis = Diagnosis::default();
        let waiting = tokio::spawn({
            let diagnosis = diagnosis.clone();
            async move { diagnosis.given_up().await }
        });
        diagnosis.give_up();
        tokio::time::timeout(std::time::Duration::from_secs(1), waiting).await.unwrap().unwrap();
        let reached = Diagnosis::default();
        reached.reached();
        reached.give_up();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), reached.given_up()).await.is_err(),
            "a dial that reached its peer is not blocked"
        );
    }
}
