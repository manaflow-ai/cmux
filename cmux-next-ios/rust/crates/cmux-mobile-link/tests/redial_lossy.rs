//! Measurement, not a check (ignored by default): Leo's endless reattach under a lossy phone link.
//! A link that connects and then fails its first probe, every time, driven through the reconnect
//! machine (`cmux_mobile_link::reconnect`) with real WireGuard dials shaped by cmux-fault's
//! `lossy-3` profile (`testing::shape_by_profile`: rate, delay, jitter and 3 % loss per datagram).
//!
//! One harness, two arms:
//! - `before`: the machine with no clock (`Machine::now` None), the rule before the stable reset:
//!   every lost link starts over at attempt 1.
//! - `after`: the machine told the time, so a link lost before `policy::STABLE_AFTER` counts as a
//!   failed attempt and the backoff grows, then stops and offers Retry.
//!
//! Time is virtual where nothing real happens and wall where something does: each dial costs its
//! measured wall time; the link's first probe fails after the heartbeat and the probe timeout
//! (`timings::HEARTBEAT` + `timings::PROBE_TIMEOUT`, as the app's controller); a scheduled retry
//! costs its delay. The budget is `REDIAL_BUDGET_S` virtual seconds (600).
//!
//! `cargo test -p cmux-mobile-link --test redial_lossy -- --ignored --nocapture` prints one
//! `REDIAL_LOSSY {json}` line per arm: the dials made in the budget, the virtual time to the first
//! Retry offer (a wait past `policy::RECONNECTING_ATTEMPTS`; null when never), and whether the
//! machine stopped on its own.

use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::reconnect::policy;
use cmux_mobile_link::reconnect::timings::{HEARTBEAT, PROBE_TIMEOUT};
use cmux_mobile_link::reconnect::{Effect, Event, Machine, Phase, Target};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::json;

const PROFILE: &str = "lossy-3";

struct Bench {
    _server: FakeSignaling,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
}

impl Bench {
    async fn start() -> Bench {
        let options = DialOptions {
            include_loopback: true,
            impair_inbound: Some(shape_by_profile),
            timeout: Duration::from_secs(40),
            ..DialOptions::default()
        };
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let mac_options = options.clone();
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options) = (mac.clone(), mac_options.clone());
                tokio::spawn(async move {
                    if let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    {
                        while connected.link.accept().await.is_some() {}
                    }
                });
            }
        });
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone =
            SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
        Bench { _server: server, phone, mac_id, options }
    }

    /// One real shaped dial: the event it ends in and its wall time.
    async fn dial(&self, generation: cmux_mobile_link::reconnect::Generation) -> (Event, Duration) {
        let start = Instant::now();
        let result = dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &self.options,
            LinkConfig::default(),
        )
        .await;
        let took = start.elapsed();
        let event = match result {
            Ok(connected) => {
                let path = *connected.path.borrow();
                connected.link.close("first probe failed");
                Event::DialSucceeded { generation, path }
            }
            Err(error) => Event::DialFailed { generation, reason: format!("{error:?}") },
        };
        (event, took)
    }
}

struct Arm {
    dials: u32,
    dials_failed: u32,
    retry_offered_s: Option<f64>,
    stopped_s: Option<f64>,
    max_attempt: u32,
    dial_ms: Vec<f64>,
}

async fn run(bench: &Bench, with_clock: bool, budget: Duration) -> Arm {
    let mut machine = Machine::new(TransportKind::WireGuard, false, false);
    // The drop path without a standby link: the one this measures (a link that never answers).
    machine.keeps_standby = false;
    let mut now = Duration::ZERO;
    let mut arm = Arm {
        dials: 0,
        dials_failed: 0,
        retry_offered_s: None,
        stopped_s: None,
        max_attempt: 0,
        dial_ms: Vec::new(),
    };
    let target = Target { mac_id: bench.mac_id.clone(), name: "Studio".into(), is_online: true };
    let mut pending = vec![Event::Target(Some(target))];
    while let Some(event) = pending.pop() {
        if now >= budget {
            break;
        }
        machine.now = with_clock.then_some(now);
        let effects = machine.handle(&event);
        if let Phase::Waiting { attempt, .. } | Phase::Connecting { attempt, .. } = machine.phase() {
            arm.max_attempt = arm.max_attempt.max(*attempt);
        }
        if let Phase::Waiting { attempt, .. } = machine.phase()
            && policy::offers_retry(*attempt)
            && arm.retry_offered_s.is_none()
        {
            arm.retry_offered_s = Some(now.as_secs_f64());
        }
        let mut scheduled = false;
        for effect in effects {
            match effect {
                Effect::Dial { generation, .. } => {
                    scheduled = true;
                    arm.dials += 1;
                    let (result, took) = bench.dial(generation).await;
                    arm.dial_ms.push(took.as_secs_f64() * 1000.0);
                    now += took;
                    match result {
                        Event::DialSucceeded { .. } => {
                            pending.push(Event::ProbeFailed { generation, reason: "timeout".into() });
                            // Pushed first, so handled first: the link connects, then its first
                            // probe fails after the heartbeat and the probe timeout.
                            pending.push(result);
                        }
                        other => {
                            arm.dials_failed += 1;
                            pending.push(other);
                        }
                    }
                }
                Effect::ScheduleRetry { generation, after } => {
                    scheduled = true;
                    now += after;
                    pending.push(Event::RetryDue { generation });
                }
                _ => {}
            }
        }
        if let Event::DialSucceeded { .. } = event {
            now += HEARTBEAT + PROBE_TIMEOUT;
        }
        if !scheduled && pending.is_empty() {
            if matches!(machine.phase(), Phase::Waiting { .. }) {
                arm.stopped_s = Some(now.as_secs_f64());
            }
            break;
        }
    }
    arm
}

fn percentile(values: &[f64], p: f64) -> Option<f64> {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    (!sorted.is_empty()).then(|| sorted[((sorted.len() - 1) as f64 * p).round() as usize])
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn lossy_first_probe_fails() {
    let budget = Duration::from_secs(
        std::env::var("REDIAL_BUDGET_S").ok().and_then(|s| s.parse().ok()).unwrap_or(600),
    );
    set_link_profile(Some(LinkProfile::named(PROFILE)), 0x5244_0000);
    for (name, with_clock) in [("before", false), ("after", true)] {
        let bench = Bench::start().await;
        let arm = run(&bench, with_clock, budget).await;
        println!(
            "REDIAL_LOSSY {}",
            json!({"arm": name, "profile": PROFILE, "budget_s": budget.as_secs(),
                   "load": "lossy-3 shaper (cmux-fault), real WireGuard dials, first probe always fails",
                   "dials": arm.dials, "dials_failed": arm.dials_failed,
                   "retry_offered_s": arm.retry_offered_s, "stopped_s": arm.stopped_s,
                   "max_attempt": arm.max_attempt,
                   "dial_ms_p50": percentile(&arm.dial_ms, 0.5), "dial_ms_p95": percentile(&arm.dial_ms, 0.95)})
        );
        if with_clock {
            assert!(arm.retry_offered_s.is_some(), "after: Retry is offered");
            assert!(arm.stopped_s.is_some(), "after: the redial stops on its own");
        }
    }
    set_link_profile(None, 0);
}
