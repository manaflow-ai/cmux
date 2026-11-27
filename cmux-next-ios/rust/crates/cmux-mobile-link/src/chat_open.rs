//! Opening a chat on the `acpmux` channel: `initialize`, `_acpmux/watch` and
//! `_acpmux/attach`, and the first page of the chat in the attach reply.
//!
//! Serial (the default, what the app does today): `initialize` and the watch go
//! out together, and the attach only once both are answered. First content costs
//! two round trips on the channel, one for the pair and one for the attach.
//!
//! Pipelined (`CMUX_PIPELINED_CHAT_OPEN=1`, off by default): all three go out in
//! one flight right after the channel opens, so first content costs one. acpmux
//! answers each request on a connection in order, so the attach is read after
//! `initialize` succeeded. If `initialize` is refused, the watch and attach sent
//! with it are dropped (their replies are ignored), `initialize` is sent once
//! more, and once it succeeds the watch and attach are sent again, once. A second
//! refusal fails the open as the serial one does.
//!
//! The requests are the caller's ([`ChatRpc`]), so the app's link and a bench's
//! fake share this sequence.

use std::future::Future;

use serde_json::Value;

/// The environment variable that turns pipelining on ("1", "on" or "true").
pub const PIPELINED_CHAT_OPEN_ENV: &str = "CMUX_PIPELINED_CHAT_OPEN";

/// Whether [`PIPELINED_CHAT_OPEN_ENV`] asks for the pipelined open. Off when unset.
pub fn pipelined_from_env() -> bool {
    std::env::var(PIPELINED_CHAT_OPEN_ENV)
        .map(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "on" | "true"))
        .unwrap_or(false)
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
    /// The id the attach reply answered (`attach`, or `attach.retry` after a
    /// refused `initialize`).
    pub attach_id: &'static str,
    /// `initialize` was refused once and the open went through on the retry.
    pub retried: bool,
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

/// Open the chat: serial, or pipelined when `pipelined` (see the module docs).
pub async fn open_chat<R: ChatRpc>(
    rpc: &mut R,
    requests: &ChatOpenRequests,
    pipelined: bool,
) -> Result<ChatOpened, String> {
    rpc.post("init", "initialize", requests.initialize.clone()).await?;
    rpc.post("watch", "_acpmux/watch", requests.watch.clone()).await?;
    if !pipelined {
        let initialize = checked(rpc, "init").await?;
        let watch = checked(rpc, "watch").await?;
        rpc.post("attach", "_acpmux/attach", requests.attach.clone()).await?;
        let attach = checked(rpc, "attach").await?;
        return Ok(ChatOpened { initialize, watch, attach, attach_id: "attach", retried: false });
    }
    rpc.post("attach", "_acpmux/attach", requests.attach.clone()).await?;
    let initialize = rpc.answer("init").await?;
    if refusal("init", &initialize).is_none() {
        let watch = checked(rpc, "watch").await?;
        let attach = checked(rpc, "attach").await?;
        return Ok(ChatOpened { initialize, watch, attach, attach_id: "attach", retried: false });
    }
    // Refused: what went with it is dropped. New ids, so a late reply to the
    // first watch or attach is never taken for the retry's.
    rpc.post("init.retry", "initialize", requests.initialize.clone()).await?;
    let initialize = checked(rpc, "init.retry").await?;
    rpc.post("watch.retry", "_acpmux/watch", requests.watch.clone()).await?;
    rpc.post("attach.retry", "_acpmux/attach", requests.attach.clone()).await?;
    let watch = checked(rpc, "watch.retry").await?;
    let attach = checked(rpc, "attach.retry").await?;
    Ok(ChatOpened { initialize, watch, attach, attach_id: "attach.retry", retried: true })
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};

    use serde_json::json;

    use super::*;

    /// A fake acpmux that answers in order and records what it saw, refusing the
    /// first `refusals` initializes; requests before a successful initialize are
    /// refused too, as an uninitialized connection would.
    #[derive(Default)]
    struct Fake {
        refusals: usize,
        initialized: bool,
        sent: Vec<(String, String)>,
        /// Requests posted since the last `answer` (one flight).
        flights: Vec<Vec<String>>,
        in_flight: Vec<String>,
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
            self.replies.push_back((id.to_owned(), reply));
            Ok(())
        }

        async fn answer(&mut self, id: &str) -> Result<Value, String> {
            if !self.in_flight.is_empty() {
                self.flights.push(std::mem::take(&mut self.in_flight));
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

    fn block<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().build().expect("runtime").block_on(future)
    }

    #[test]
    fn serial_waits_for_initialize_and_watch_before_attach() {
        let mut fake = Fake::default();
        let opened = block(open_chat(&mut fake, &requests(), false)).expect("open");
        assert_eq!(opened.attach_id, "attach");
        assert_eq!(
            fake.flights,
            vec![
                vec!["initialize".to_owned(), "_acpmux/watch".to_owned()],
                vec!["_acpmux/attach".to_owned()]
            ]
        );
    }

    #[test]
    fn pipelined_sends_all_three_in_one_flight() {
        let mut fake = Fake::default();
        let opened = block(open_chat(&mut fake, &requests(), true)).expect("open");
        assert!(!opened.retried);
        assert_eq!(opened.attach["result"]["method"], "_acpmux/attach");
        assert_eq!(
            fake.flights,
            vec![vec!["initialize".to_owned(), "_acpmux/watch".to_owned(), "_acpmux/attach".to_owned()]]
        );
    }

    #[test]
    fn refused_initialize_drops_the_attach_and_resends_it_once() {
        let mut fake = Fake { refusals: 1, ..Fake::default() };
        let opened = block(open_chat(&mut fake, &requests(), true)).expect("open");
        assert!(opened.retried);
        assert_eq!(opened.attach_id, "attach.retry");
        assert_eq!(opened.attach["result"]["method"], "_acpmux/attach");
        let attaches = fake.sent.iter().filter(|(_, method)| method == "_acpmux/attach").count();
        assert_eq!(attaches, 2, "the first attach and one resend");
        // The resend goes only after the retried initialize was answered.
        let retry_init =
            fake.flights.iter().position(|f| f == &vec!["initialize".to_owned()]).expect("retry");
        assert_eq!(
            fake.flights[retry_init + 1],
            vec!["_acpmux/watch".to_owned(), "_acpmux/attach".to_owned()]
        );
    }

    #[test]
    fn initialize_refused_twice_fails_the_open() {
        let mut fake = Fake { refusals: 2, ..Fake::default() };
        let error = block(open_chat(&mut fake, &requests(), true)).expect_err("refused");
        assert!(error.starts_with("init.retry:"), "{error}");
        let attaches = fake.sent.iter().filter(|(_, method)| method == "_acpmux/attach").count();
        assert_eq!(attaches, 1, "no resend without a successful initialize");
    }

    #[test]
    fn serial_refused_initialize_fails_without_attach() {
        let mut fake = Fake { refusals: 1, ..Fake::default() };
        assert!(block(open_chat(&mut fake, &requests(), false)).is_err());
        assert!(fake.sent.iter().all(|(_, method)| method != "_acpmux/attach"));
    }

    #[test]
    fn env_flag_defaults_off() {
        // Only reads; the variable is not set in the test environment.
        if std::env::var_os(PIPELINED_CHAT_OPEN_ENV).is_none() {
            assert!(!pipelined_from_env());
        }
    }
}
