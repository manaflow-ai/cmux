//! The cloud link: the brain's connection to a cmux-tui daemon that proxies
//! cloud conversations (`cloud-conversations-v1`). It leases a chief token
//! to the daemon (`cloud-session-set`), subscribes to the chief's main
//! conversation and to its wake queue (`cloud-mux-subscribe`, G9), hands the
//! brain a port, turns cloud events into the same `DaemonEvent`s the local
//! owner produces (and wakes into `DaemonEvent::MuxWake`), renews the lease
//! before it expires or when the daemon asks, and reconnects after any loss.
//!
//! The lease is daemon-wide: every unbound local client of that daemon acts
//! as the chief. So the brain gets a daemon of its own (DESIGN section 3).

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_conversation::Change;
use serde_json::{Value, json};

use super::CAPABILITY;
use super::auth::{Lease, TokenSource};
use super::events::{CloudSignal, map_event};
use super::port::CloudPort;
use super::wire::{LineClient, Rpc};
use crate::daemon::{ConversationPort, DaemonEvent, OpError};

/// Renew a lease this long before it expires (the daemon asks at 120 s too).
const RENEW_BEFORE_MS: u64 = 150_000;
/// How often the event loop wakes to check the lease.
const TICK: Duration = Duration::from_secs(1);

#[derive(Clone, Debug)]
pub struct CloudLinkConfig {
    /// The brain's own cmux-tui daemon socket.
    pub socket: std::path::PathBuf,
    /// The chief id (`agent_...`): the token's `agent`, `agent_mux` inside the brain.
    pub chief: String,
    /// The chief's main conversation (`conv_...`).
    pub conversation: String,
}

enum Ended {
    Fatal(String),
    Retry(String),
}

type Sink = Arc<dyn Fn(DaemonEvent) + Send + Sync>;
type Log = Arc<dyn Fn(&str) + Send + Sync>;

/// Runs the cloud link on its own thread.
pub fn spawn_cloud_link(
    config: CloudLinkConfig,
    tokens: Arc<dyn TokenSource>,
    sink: Sink,
    log: Log,
) {
    std::thread::Builder::new()
        .name("cloud-link".into())
        .spawn(move || {
            let mut delay = Duration::from_millis(500);
            loop {
                let started = Instant::now();
                match session(&config, &*tokens, &sink, &log) {
                    Ok(()) => {}
                    Err(Ended::Fatal(why)) => {
                        sink(DaemonEvent::Fatal(why));
                        return;
                    }
                    Err(Ended::Retry(why)) => log(&format!("cloud link: {why}")),
                }
                if started.elapsed() > Duration::from_secs(30) {
                    delay = Duration::from_millis(500);
                }
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(30));
            }
        })
        .expect("spawn cloud link");
}

fn retry(e: impl std::fmt::Display) -> Ended {
    Ended::Retry(e.to_string())
}

fn set_lease(control: &mut LineClient, lease: &Lease) -> Result<(), Ended> {
    control
        .call(
            "cloud-session-set",
            json!({
                "api_base_url": lease.api_base_url,
                "access_token": lease.access_token,
                "expires_at": lease.expires_at,
                "client_version": concat!("optchat-chief/", env!("CARGO_PKG_VERSION")),
            }),
        )
        .map(|_| ())
        .map_err(retry)
}

/// G9: subscribes the chief's wake queue on the current lease (the daemon
/// takes the chief from the lease's token; the request names none). Called
/// on every connect and after every new lease. A refusal (a person's lease:
/// `mux_needs_chief`) is logged, not retried: the main conversation runs.
fn subscribe_queue(control: &mut LineClient, log: &Log) -> Result<(), Ended> {
    match control.call("cloud-mux-subscribe", json!({})) {
        Ok(_) => {
            log("cloud wake queue subscribed");
            Ok(())
        }
        Err(OpError::Rejected(why)) => {
            log(&format!(
                "the daemon refused the chief's wake queue ({why}); only the main conversation is answered"
            ));
            Ok(())
        }
        Err(e) => Err(retry(e)),
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// One connected session; returns when the subscription ends.
fn session(
    config: &CloudLinkConfig,
    tokens: &dyn TokenSource,
    sink: &Sink,
    log: &Log,
) -> Result<(), Ended> {
    let connect = |timeout| {
        LineClient::connect(&config.socket, timeout)
            .map_err(|e| retry(format!("{}: {e}", config.socket.display())))
    };
    let mut control = connect(Duration::from_secs(60))?;
    let identity = control.call("identify", json!({})).map_err(retry)?;
    let capable = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|caps| caps.iter().any(|c| c.as_str() == Some(CAPABILITY)));
    if !capable {
        let text = |k: &str| identity.get(k).map_or_else(|| "?".into(), Value::to_string);
        return Err(Ended::Fatal(format!(
            "daemon at {} ({} {}) lacks {CAPABILITY}: run a cmux-tui built from feat-cmux-next",
            config.socket.display(),
            text("app"),
            text("version")
        )));
    }
    let mut lease = tokens
        .mint(Some(&config.chief))
        .map_err(|e| retry(format!("minting a chief token: {e}")))?;
    set_lease(&mut control, &lease)?;
    log(&format!(
        "cloud lease set until {} (chief {})",
        lease.expires_at, config.chief
    ));

    // Events first, then the cloud subscription, then the snapshot: no change
    // falls between them.
    let mut events = connect(TICK)?;
    events.call("subscribe", json!({})).map_err(retry)?;
    let state = control
        .call(
            "cloud-conversation-subscribe",
            json!({"conversation": config.conversation}),
        )
        .map_err(retry)?;
    log(&format!(
        "cloud conversation {} subscribed ({})",
        config.conversation,
        state.get("state").and_then(Value::as_str).unwrap_or("?")
    ));
    subscribe_queue(&mut control, log)?;
    let mut port = CloudPort::new(connect(Duration::from_secs(60))?, config.chief.clone());
    let (summary, _) = match port.snapshot(&config.conversation, 1) {
        Ok(found) => found,
        Err(OpError::Rejected(why)) => {
            return Err(retry(format!(
                "the cloud refused the chief's conversation {} ({why}); check the chief id and its main conversation",
                config.conversation
            )));
        }
        Err(e) => return Err(retry(e)),
    };
    let closer = events.closer().map_err(retry)?;
    sink(DaemonEvent::Up {
        port: Box::new(port),
        conversation: summary,
        reconnect: Box::new(move || {
            let _ = closer.shutdown(std::net::Shutdown::Both);
        }),
    });

    let ended = loop {
        if now_ms() + RENEW_BEFORE_MS >= lease.expires_at {
            match tokens.mint(Some(&config.chief)) {
                Ok(next) => {
                    if set_lease(&mut control, &next).is_err() {
                        break "the daemon refused the renewed lease".to_owned();
                    }
                    lease = next;
                    // The queue is subscribed again on every new lease.
                    if let Err(Ended::Retry(why) | Ended::Fatal(why)) =
                        subscribe_queue(&mut control, log)
                    {
                        break why;
                    }
                }
                // Keep the old lease; the daemon asks again when it expires.
                Err(e) => log(&format!("renewing the chief token: {e}")),
            }
        }
        let raw = match events.next_event() {
            Ok(Some(raw)) => raw,
            Ok(None) => continue,
            Err(e) => break format!("event connection closed: {e}"),
        };
        match map_event(&raw, &config.conversation, &config.chief) {
            Some(CloudSignal::Changed(change)) => sink(DaemonEvent::Changed {
                conversation: config.conversation.clone(),
                change,
            }),
            Some(CloudSignal::Resynced { summary, messages }) => {
                // The brain skips what it handled and pages back over a gap.
                sink(DaemonEvent::Changed {
                    conversation: config.conversation.clone(),
                    change: Change::Conversation {
                        conversation: Box::new(summary),
                    },
                });
                for message in messages {
                    sink(DaemonEvent::Changed {
                        conversation: config.conversation.clone(),
                        change: Change::Message { message },
                    });
                }
            }
            Some(CloudSignal::State { live: true, .. }) => log("cloud conversation live"),
            Some(CloudSignal::State { state, .. }) if state == "connecting" => {}
            Some(CloudSignal::State { state, reason, .. }) => {
                break format!(
                    "cloud conversation {state} ({})",
                    reason.unwrap_or_default()
                );
            }
            Some(CloudSignal::SessionNeeded(reason)) => {
                log(&format!("the daemon asks for a new lease ({reason})"));
                match tokens.mint(Some(&config.chief)) {
                    Ok(next) => {
                        if set_lease(&mut control, &next).is_err() {
                            break "the daemon refused the renewed lease".to_owned();
                        }
                        lease = next;
                        // The queue is subscribed again on every new lease.
                        if let Err(Ended::Retry(why) | Ended::Fatal(why)) =
                            subscribe_queue(&mut control, log)
                        {
                            break why;
                        }
                    }
                    Err(e) => break format!("minting a chief token: {e}"),
                }
            }
            Some(CloudSignal::MuxWakes(wakes)) => sink(DaemonEvent::MuxWake(wakes)),
            None => {}
        }
    };
    log(&format!("cloud link down: {ended}"));
    sink(DaemonEvent::Down);
    Ok(())
}
