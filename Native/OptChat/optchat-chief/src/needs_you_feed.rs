//! Sign-ins that wait on the person, as open Feed requests (Needs you).
//!
//! A subagent's `escalate_auth` asks the Chief to drive a sign-in, which ends
//! with the person touching the sensor or typing a password in Home's right
//! pane. Until now only the Chief's chat line ("Needs you: touch the sensor
//! (SITE)") said so. Each escalation now also posts one open `sign-in` (or
//! `passkey`) request to the person's Feed through the app's `feed.request`
//! control method, so it sits in the Feed's pinned Needs you section and in
//! whatever Home and the iPhone read from the Feed. The request is withdrawn
//! (`feed.cancel`) when the Chief tells the subagent it is signed in, or when
//! the subagent is cancelled; otherwise it lapses after [`EXPIRES_IN_MS`].
//!
//! The posts and cancels run in order on one worker thread
//! ([`SignInRequests::new`]), off the brain's loop; the thread ends when the
//! brain drops its [`SignInRequests`] (its channel closes).

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Sender, channel};
use std::time::Duration;

use serde_json::{Value, json};

use crate::tools::AuthEscalation;

/// How long an unresolved sign-in request stays in the Feed: sign-in pages
/// and passkey prompts time out well before this.
pub const EXPIRES_IN_MS: u64 = 60 * 60 * 1000;

/// The Feed as the Chief host reaches it: the app's control socket.
pub trait FeedPort: Send + Sync {
    /// Posts (`feed.post` params) under idempotency key `key`; the item id.
    fn request(&self, post: &Value, key: &str) -> Result<String, String>;
    /// Withdraws item `item` with a feed cancel `reason`.
    fn cancel(&self, item: &str, reason: &str) -> Result<(), String>;
}

/// [`FeedPort`] over the app's control socket (`CMUX_SOCKET_PATH`), whose
/// `feed.request`/`feed.cancel` post as the signed-in person.
pub struct ControlSocketFeed {
    pub socket: PathBuf,
}

const CALL_TIMEOUT: Duration = Duration::from_secs(30);

impl ControlSocketFeed {
    /// The app's control socket from the host's env; None without an app.
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<ControlSocketFeed> {
        env("CMUX_SOCKET_PATH")
            .filter(|s| !s.is_empty())
            .map(|socket| ControlSocketFeed {
                socket: socket.into(),
            })
    }
}

impl FeedPort for ControlSocketFeed {
    fn request(&self, post: &Value, key: &str) -> Result<String, String> {
        let request = json!({"id": 1, "method": "feed.request",
            "params": {"post": post, "idempotency_key": key}});
        let result = crate::workspaces::control_call(&self.socket, &request, CALL_TIMEOUT)?;
        result["item"]["id"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| format!("feed.request answered no item: {result}"))
    }

    fn cancel(&self, item: &str, reason: &str) -> Result<(), String> {
        let request = json!({"id": 1, "method": "feed.cancel",
            "params": {"item": item, "reason": reason}});
        crate::workspaces::control_call(&self.socket, &request, CALL_TIMEOUT).map(|_| ())
    }
}

/// The Feed dedupe key of subagent `agent`'s sign-in to `site` on Chief
/// `chief`: a second escalation of the same site joins the open item.
pub fn dedupe_key(chief: &str, agent: &str, site: &str) -> String {
    let key = format!(
        "chief-auth:{chief}:{agent}:{}",
        site.trim().to_ascii_lowercase()
    );
    key.chars().take(200).collect()
}

/// `scheme://host[:port]` of `url`, or `https://SITE` when it has none.
fn origin(url: &str, site: &str) -> String {
    url.split_once("://")
        .map(|(scheme, rest)| {
            let host = rest.split(['/', '?', '#']).next().unwrap_or("");
            format!("{scheme}://{host}")
        })
        .filter(|o| !o.ends_with("://"))
        .unwrap_or_else(|| format!("https://{site}"))
}

fn cut(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

/// The `feed.post` params for `request` from subagent `agent` of Chief
/// `chief` (`session`: the subagent's acpmux session, when it has one).
///
/// A `passkey` escalation posts a `passkey` request; every other kind
/// (`password`, `2fa`, `oauth`) a `sign-in` request. Neither names a real
/// browser tab id (the Chief opens its tab after this): `browser_tab` names
/// the Chief's right pane for that subagent.
pub fn post(chief: &str, agent: &str, request: &AuthEscalation, session: Option<&str>) -> Value {
    let site = request.site.trim();
    let tab = cut(&format!("chief:{chief}:{agent}"), 128);
    let reason = cut(request.reason.trim(), 500);
    let origin = cut(&origin(&request.url, site), 300);
    let passkey = request.kind == "passkey";
    let (kind, title, prompt) = if passkey {
        (
            "passkey",
            format!("Use your passkey for {site}"),
            json!({"origin": origin, "rp_id": cut(site, 300), "ceremony": "get",
                "browser_tab": tab, "reason": reason}),
        )
    } else {
        (
            "sign-in",
            format!("Sign in to {site}"),
            json!({"origin": origin, "url": cut(&request.url, 2048),
                "browser_tab": tab, "reason": reason}),
        )
    };
    let mut context = json!({"url": cut(&request.url, 2048)});
    if let Some(session) = session {
        context["acp_session"] = json!(cut(session, 128));
    }
    json!({
        "type": "request",
        "kind": kind,
        "title": cut(&title, 200),
        "body": cut(&format!("{agent} needs it: {reason}. Your Chief opens it in Home's right pane."), 4096),
        "prompt": prompt,
        "dedupe_key": dedupe_key(chief, agent, site),
        "thread": cut(&format!("chief:{chief}:{agent}"), 200),
        "context": context,
        "expires_in_ms": EXPIRES_IN_MS,
        "poster": {"kind": "agent", "label": "Chief"},
    })
}

/// Whether a Chief message to the subagent says its sign-in to `site` is
/// done (the skill's `tell(aN, "Signed in to SITE in tab ...; go on.")`).
/// `only`: the subagent waits on this one sign-in alone, so a message that
/// says it is signed in without naming the site counts too.
pub fn says_signed_in(message: &str, site: &str, only: bool) -> bool {
    let text = message.to_ascii_lowercase();
    let signed = [
        "signed in",
        "signed-in",
        "logged in",
        "sign-in is done",
        "sign-in done",
    ]
    .iter()
    .any(|w| text.contains(w));
    // "not signed in yet", "isn't logged in": the sign-in still waits.
    let negated = [
        "not signed in",
        "n't signed in",
        "not logged in",
        "n't logged in",
        "not yet signed in",
    ]
    .iter()
    .any(|w| text.contains(w));
    let site = site.trim().to_ascii_lowercase();
    let bare = site.strip_prefix("www.").unwrap_or(&site);
    signed && !negated && (only || (!bare.is_empty() && text.contains(bare)))
}

enum Op {
    /// `idempotency`: one per escalation, so a new escalation after the item
    /// closed posts again instead of replaying the closed one.
    Post {
        key: String,
        idempotency: String,
        post: Value,
    },
    Cancel {
        key: String,
        reason: &'static str,
    },
}

/// The open sign-in requests of one Chief, by dedupe key.
pub struct SignInRequests {
    chief: String,
    tx: Option<Sender<Op>>,
    /// Open requests: dedupe key -> (subagent, site).
    open: BTreeMap<String, (String, String)>,
    /// Posts so far (part of each post's idempotency key).
    posts: u64,
}

impl SignInRequests {
    /// None: no app to post to; every call is a no-op.
    pub fn new(
        chief: &str,
        port: Option<Arc<dyn FeedPort>>,
        log: crate::brain::Log,
    ) -> SignInRequests {
        let tx = port.map(|port| {
            let (tx, rx) = channel::<Op>();
            // Ends when the brain drops its sender.
            std::thread::Builder::new()
                .name("chief-needs-you-feed".into())
                .spawn(move || {
                    let mut items: HashMap<String, String> = HashMap::new();
                    for op in rx {
                        match op {
                            Op::Post {
                                key,
                                idempotency,
                                post,
                            } => match port.request(&post, &idempotency) {
                                Ok(item) => {
                                    items.insert(key, item);
                                }
                                Err(e) => {
                                    log(&format!("needs you: posting {key} to the Feed: {e}"))
                                }
                            },
                            Op::Cancel { key, reason } => {
                                if let Some(item) = items.remove(&key)
                                    && let Err(e) = port.cancel(&item, reason)
                                {
                                    log(&format!("needs you: withdrawing {key} ({item}): {e}"));
                                }
                            }
                        }
                    }
                })
                .ok()
                .map(|_| tx)
        });
        SignInRequests {
            chief: chief.to_owned(),
            tx: tx.flatten(),
            open: BTreeMap::new(),
            posts: 0,
        }
    }

    /// Subagent `agent` escalated `request`: one open Feed request for it.
    pub fn opened(&mut self, agent: &str, request: &AuthEscalation, session: Option<&str>) {
        let key = dedupe_key(&self.chief, agent, &request.site);
        self.open.insert(
            key.clone(),
            (agent.to_owned(), request.site.trim().to_owned()),
        );
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        self.posts += 1;
        let idempotency = format!(
            "{}:{at}:{}",
            key.chars().take(160).collect::<String>(),
            self.posts
        );
        self.send(Op::Post {
            key,
            idempotency,
            post: post(&self.chief, agent, request, session),
        });
    }

    /// The Chief told `agent` `message`: the sign-ins it says are done close.
    pub fn told(&mut self, agent: &str, message: &str) {
        let mine: Vec<(String, String)> = self
            .open
            .iter()
            .filter(|(_, (a, _))| a == agent)
            .map(|(k, (_, site))| (k.clone(), site.clone()))
            .collect();
        let only = mine.len() == 1;
        for (key, site) in mine {
            if says_signed_in(message, &site, only) {
                self.close(&key, "answered_elsewhere");
            }
        }
    }

    /// Subagent `agent` is cancelled: nobody waits on its sign-ins now.
    pub fn abandoned(&mut self, agent: &str) {
        let keys: Vec<String> = self
            .open
            .iter()
            .filter(|(_, (a, _))| a == agent)
            .map(|(k, _)| k.clone())
            .collect();
        for key in keys {
            self.close(&key, "poster_gone");
        }
    }

    /// The open requests' dedupe keys.
    pub fn open_keys(&self) -> Vec<String> {
        self.open.keys().cloned().collect()
    }

    fn close(&mut self, key: &str, reason: &'static str) {
        if self.open.remove(key).is_some() {
            self.send(Op::Cancel {
                key: key.to_owned(),
                reason,
            });
        }
    }

    fn send(&self, op: Op) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(op);
        }
    }
}
