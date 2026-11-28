//! Opening a chat on the `acpmux` channel: `initialize`, `_acpmux/watch` and
//! `_acpmux/attach`, and the first page of the chat in the attach reply.
//!
//! Serial (the default): `initialize` and the watch go out together, and the
//! attach only once both are answered. First content costs two round trips on the
//! channel, one for the pair and one for the attach.
//!
//! Pipelined (`CMUX_PIPELINED_CHAT_OPEN=1`, off by default): all three go out in
//! one flight right after the channel opens, so first content costs one round
//! trip. acpmux answers a connection's requests in order, so the attach is
//! answered after `initialize`. The iOS app's Swift hub already sends its chats'
//! attaches in this burst (`AcpmuxHub.pipelineAttaches`); this is the same order
//! for Rust clients, and for the ios-mac bench to measure.
//!
//! A refused `initialize` is handled the same way in both modes, so the two
//! differ only in the round trip. Whatever went out with it is dropped and its
//! replies are ignored. After [`RETRY_BACKOFF`], the whole open is sent once more
//! in the same mode, under new ids (`init.retry`, `watch.retry`,
//! `attach.retry`), so a late reply to the first try is never taken for the
//! retry's. A second refusal fails the open. There is one retry and no loop.
//!
//! The requests go through the caller's [`ChatRpc`], so a link and a bench's fake
//! share this sequence.

use std::future::Future;
use std::time::Duration;

use serde_json::Value;

/// The environment variable that turns pipelining on ("1", "on" or "true").
pub const PIPELINED_CHAT_OPEN_ENV: &str = "CMUX_PIPELINED_CHAT_OPEN";

/// The wait before the one retry after a refused `initialize`.
pub const RETRY_BACKOFF: Duration = Duration::from_millis(200);

/// Whether a value of [`PIPELINED_CHAT_OPEN_ENV`] turns pipelining on: "1",
/// "on" or "true", in any case and with surrounding spaces. Off when unset or
/// anything else.
pub fn pipelined_flag(value: Option<&str>) -> bool {
    value.is_some_and(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "on" | "true"))
}

/// [`pipelined_flag`] of the process environment.
pub fn pipelined_from_env() -> bool {
    pipelined_flag(std::env::var(PIPELINED_CHAT_OPEN_ENV).ok().as_deref())
}

/// JSON-RPC over one `acpmux` channel, as the opener needs it.
pub trait ChatRpc {
    /// Send one request with this `id`.
    fn post(&mut self, id: &str, method: &str, params: Value) -> impl Future<Output = Result<(), String>>;
    /// The reply to `id` (a `result` or an `error` object), whatever order replies
    /// arrive in.
    fn answer(&mut self, id: &str) -> impl Future<Output = Result<Value, String>>;
}

/// What the three requests carry.
#[derive(Clone, Debug)]
pub struct ChatOpenRequests {
    pub initialize: Value,
    pub watch: Value,
    pub attach: Value,
}

/// The replies an open ended with.
#[derive(Clone, Debug)]
pub struct ChatOpened {
    pub initialize: Value,
    pub watch: Value,
    pub attach: Value,
    /// The id the attach reply answered: `attach`, or `attach.retry` after a
    /// refused `initialize`.
    pub attach_id: &'static str,
    /// `initialize` was refused once and the open went through on the retry.
    pub retried: bool,
}

struct Ids {
    init: &'static str,
    watch: &'static str,
    attach: &'static str,
}

const FIRST: Ids = Ids { init: "init", watch: "watch", attach: "attach" };
const RETRY: Ids = Ids { init: "init.retry", watch: "watch.retry", attach: "attach.retry" };

enum Attempt {
    Opened(ChatOpened),
    /// `initialize` was refused; the error.
    Refused(String),
}

fn refusal(id: &str, reply: &Value) -> Option<String> {
    reply.get("error").map(|error| format!("{id}: {error}"))
}

async fn checked<R: ChatRpc>(rpc: &mut R, id: &str) -> Result<Value, String> {
    let reply = rpc.answer(id).await?;
    match refusal(id, &reply) {
        Some(error) => Err(error),
        None => Ok(reply),
    }
}

async fn attempt<R: ChatRpc>(
    rpc: &mut R,
    requests: &ChatOpenRequests,
    pipelined: bool,
    ids: &Ids,
) -> Result<Attempt, String> {
    rpc.post(ids.init, "initialize", requests.initialize.clone()).await?;
    rpc.post(ids.watch, "_acpmux/watch", requests.watch.clone()).await?;
    if pipelined {
        rpc.post(ids.attach, "_acpmux/attach", requests.attach.clone()).await?;
    }
    let initialize = rpc.answer(ids.init).await?;
    if let Some(error) = refusal(ids.init, &initialize) {
        return Ok(Attempt::Refused(error));
    }
    let watch = checked(rpc, ids.watch).await?;
    if !pipelined {
        rpc.post(ids.attach, "_acpmux/attach", requests.attach.clone()).await?;
    }
    let attach = checked(rpc, ids.attach).await?;
    Ok(Attempt::Opened(ChatOpened { initialize, watch, attach, attach_id: ids.attach, retried: false }))
}

/// Open the chat, serial or pipelined (see the module docs).
pub async fn open_chat<R: ChatRpc>(
    rpc: &mut R,
    requests: &ChatOpenRequests,
    pipelined: bool,
) -> Result<ChatOpened, String> {
    if let Attempt::Opened(opened) = attempt(rpc, requests, pipelined, &FIRST).await? {
        return Ok(opened);
    }
    tokio::time::sleep(RETRY_BACKOFF).await;
    match attempt(rpc, requests, pipelined, &RETRY).await? {
        Attempt::Opened(opened) => Ok(ChatOpened { retried: true, ..opened }),
        Attempt::Refused(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};

    use serde_json::json;

    use super::*;

    /// A fake acpmux. It refuses the first `refusals` initializes, and refuses
    /// any other request made before an initialize succeeded, as an
    /// uninitialized connection would. It answers in order, or in reverse order
    /// within each flight when `reverse` is set. It records every flight (the
    /// requests posted between two reads).
    #[derive(Default)]
    struct Fake {
        refusals: usize,
        reverse: bool,
        initialized: bool,
        sent: Vec<(String, String)>,
        flights: Vec<Vec<String>>,
        in_flight: Vec<String>,
        pending: Vec<(String, Value)>,
        replies: VecDeque<(String, Value)>,
        stash: HashMap<String, Value>,
    }

    impl ChatRpc for Fake {
        async fn post(&mut self, id: &str, method: &str, _params: Value) -> Result<(), String> {
            self.sent.push((id.to_owned(), method.to_owned()));
            self.in_flight.push(method.to_owned());
            let reply = match method {
                "initialize" if self.refusals > 0 => {
                    self.refusals -= 1;
                    json!({"id": id, "error": {"code": -32000, "message": "not ready"}})
                }
                "initialize" => {
                    self.initialized = true;
                    json!({"id": id, "result": {}})
                }
                _ if !self.initialized => {
                    json!({"id": id, "error": {"code": -32002, "message": "not initialized"}})
                }
                _ => json!({"id": id, "result": {"method": method}}),
            };
            self.pending.push((id.to_owned(), reply));
            Ok(())
        }

        async fn answer(&mut self, id: &str) -> Result<Value, String> {
            if !self.in_flight.is_empty() {
                self.flights.push(std::mem::take(&mut self.in_flight));
                let mut flight = std::mem::take(&mut self.pending);
                if self.reverse {
                    flight.reverse();
                }
                self.replies.extend(flight);
            }
            if let Some(reply) = self.stash.remove(id) {
                return Ok(reply);
            }
            while let Some((got, reply)) = self.replies.pop_front() {
                if got == id {
                    return Ok(reply);
                }
                self.stash.insert(got, reply);
            }
            Err(format!("no reply to {id}"))
        }
    }

    fn requests() -> ChatOpenRequests {
        ChatOpenRequests {
            initialize: json!({"protocolVersion": 1}),
            watch: json!({"enabled": true}),
            attach: json!({"sessionId": "s"}),
        }
    }

    /// On a paused clock: the backoff passes at once, and the time it took is
    /// returned.
    fn block<F: Future>(future: F) -> (F::Output, Duration) {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .start_paused(true)
            .build()
            .expect("runtime")
            .block_on(async {
                let began = tokio::time::Instant::now();
                let out = future.await;
                (out, began.elapsed())
            })
    }

    fn methods(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    fn attaches(fake: &Fake) -> usize {
        fake.sent.iter().filter(|(_, method)| method == "_acpmux/attach").count()
    }

    #[test]
    fn serial_waits_for_initialize_and_watch_before_attach() {
        let mut fake = Fake::default();
        let (opened, _) = block(open_chat(&mut fake, &requests(), false));
        assert_eq!(opened.expect("open").attach_id, "attach");
        assert_eq!(
            fake.flights,
            vec![methods(&["initialize", "_acpmux/watch"]), methods(&["_acpmux/attach"])]
        );
    }

    #[test]
    fn pipelined_sends_all_three_in_one_flight() {
        let mut fake = Fake::default();
        let (opened, _) = block(open_chat(&mut fake, &requests(), true));
        let opened = opened.expect("open");
        assert!(!opened.retried);
        assert_eq!(opened.attach["result"]["method"], "_acpmux/attach");
        assert_eq!(fake.flights, vec![methods(&["initialize", "_acpmux/watch", "_acpmux/attach"])]);
    }

    #[test]
    fn replies_out_of_order_still_match_their_requests() {
        for pipelined in [false, true] {
            let mut fake = Fake { reverse: true, ..Fake::default() };
            let (opened, _) = block(open_chat(&mut fake, &requests(), pipelined));
            let opened = opened.expect("open");
            assert_eq!(opened.watch["result"]["method"], "_acpmux/watch", "pipelined={pipelined}");
            assert_eq!(opened.attach["result"]["method"], "_acpmux/attach", "pipelined={pipelined}");
            assert_eq!(opened.initialize["id"], "init");
        }
    }

    #[test]
    fn refused_initialize_drops_the_attach_and_resends_it_once_after_backoff() {
        let mut fake = Fake { refusals: 1, ..Fake::default() };
        let (opened, took) = block(open_chat(&mut fake, &requests(), true));
        let opened = opened.expect("open");
        assert!(opened.retried);
        assert_eq!(opened.attach_id, "attach.retry");
        assert_eq!(opened.attach["result"]["method"], "_acpmux/attach");
        assert_eq!(attaches(&fake), 2, "the first attach and one resend");
        assert!(took >= RETRY_BACKOFF, "retried after {took:?}");
        // The first try's attach was refused (sent before initialize succeeded)
        // and dropped; the retry's went in its own flight.
        assert_eq!(
            fake.flights,
            vec![
                methods(&["initialize", "_acpmux/watch", "_acpmux/attach"]),
                methods(&["initialize", "_acpmux/watch", "_acpmux/attach"]),
            ]
        );
    }

    #[test]
    fn serial_retries_a_refused_initialize_the_same_way() {
        let mut fake = Fake { refusals: 1, ..Fake::default() };
        let (opened, took) = block(open_chat(&mut fake, &requests(), false));
        let opened = opened.expect("open");
        assert!(opened.retried);
        assert_eq!(opened.attach_id, "attach.retry");
        assert_eq!(attaches(&fake), 1, "serial sends no attach before initialize succeeds");
        assert!(took >= RETRY_BACKOFF);
    }

    #[test]
    fn initialize_refused_twice_fails_the_open_with_one_retry() {
        for pipelined in [false, true] {
            let mut fake = Fake { refusals: 5, ..Fake::default() };
            let (error, _) = block(open_chat(&mut fake, &requests(), pipelined));
            let error = error.expect_err("refused");
            assert!(error.starts_with("init.retry:"), "{error}");
            let inits = fake.sent.iter().filter(|(_, method)| method == "initialize").count();
            assert_eq!(inits, 2, "one retry, no loop (pipelined={pipelined})");
        }
    }

    #[test]
    fn flag_parses_on_values_and_defaults_off() {
        for on in ["1", "on", "true", "TRUE", " On "] {
            assert!(pipelined_flag(Some(on)), "{on:?}");
        }
        for off in [None, Some("0"), Some("off"), Some("false"), Some(""), Some("yes"), Some("2")] {
            assert!(!pipelined_flag(off), "{off:?}");
        }
    }
}
