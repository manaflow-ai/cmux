//! The Mac app's own Feed requests on the phone (manaflow-ai/cmux#33818): PRs held for Leo's
//! trial (`GitHubFeedSource.heldForTrial`), sign-ins and consent cards. The phone reads acpmux
//! and the daemon's notification ledger, never the app's `FeedModel`, so the app hands hostd
//! its open requests over stdin (`{"type":"needs_you","items":[...]}`, the whole set each time
//! it changes) and hostd:
//!
//! - serves that set on the `needs-you` service (one JSON object per change,
//!   `{"items":[...]}`), so the phone's Feed pins each open request and drops it once it closes;
//! - pushes each request once (kind `question`, event id `feed-<id>`). Which ids were pushed is
//!   kept on disk (`needs-you-pushed.json`), so an app or host restart, a reconnect or a re-sent
//!   set never pushes one twice, and a request that closes and opens again is not new either.
//!
//! The app stays a thin forwarder: every rule (what is valid, what is new, what was pushed)
//! lives here.

use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::api::NotifyEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

use crate::notify::{Reporter, text_label, valid_id};
use crate::services::Refusal;

/// At most this many open requests are served and pushed (the Mac pins far fewer).
pub const MAX_ITEMS: usize = 64;
/// How many pushed ids are remembered beyond the open ones.
pub const PUSHED_LIMIT: usize = 512;
/// The push event id of a request is this and its id.
pub const EVENT_PREFIX: &str = "feed-";

/// One open request of the Mac app's Feed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    /// The Feed item id (`fi_...`, stable for one PR or one sign-in).
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub body: String,
    /// The prompt kind (`review`, `signIn`, `approve`, ...).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub kind: String,
    /// Who posted it ("GitHub").
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source: String,
    /// Where it opens (the PR), `https` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default)]
    pub created_at_ms: i64,
}

/// The app's list made safe to serve and push: valid ids only, each once, texts cut and
/// redacted, `https` links only, at most [`MAX_ITEMS`]. A request with no title is dropped.
pub fn sanitize(items: Vec<Request>) -> Vec<Request> {
    items // red: not written yet
}

/// The push for `request`: an ask (kind `question`, so every phone that wants asks gets it)
/// with no options, which opens the Feed where it is pinned.
pub fn push_event(request: &Request) -> NotifyEvent {
    let _ = request; // red: not written yet
    NotifyEvent::default()
}

/// Which requests were pushed, on disk when given a path.
#[derive(Debug, Default)]
pub struct Pushed {
    seen: HashSet<String>,
    order: VecDeque<String>,
    path: Option<PathBuf>,
}

impl Pushed {
    /// The ids pushed before (none when the file is missing or unreadable).
    pub fn load(path: Option<PathBuf>) -> Self {
        let ids: Vec<String> = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        let mut pushed = Self { path, ..Self::default() };
        for id in ids {
            if pushed.seen.insert(id.clone()) {
                pushed.order.push_back(id);
            }
        }
        pushed
    }

    /// The pushes for the requests of `open` never pushed before, recorded (and saved).
    pub fn pushes(&mut self, open: &[Request]) -> Vec<NotifyEvent> {
        let _ = (open, &self.path); // red: not written yet
        Vec::new()
    }
}

fn save(path: &Path, ids: &VecDeque<String>) -> Result<(), String> {
    let parent = path.parent().ok_or("no parent")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let data = serde_json::to_vec(ids).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn open_sender() -> &'static watch::Sender<Vec<Request>> {
    static OPEN: OnceLock<watch::Sender<Vec<Request>>> = OnceLock::new();
    OPEN.get_or_init(|| watch::channel(Vec::new()).0)
}

/// The app's whole set of open requests (`needs_you` control line). Phones and the pusher hear
/// it only when it changed.
pub fn set(items: Vec<Request>) {
    let _ = (items, open_sender()); // red: not written yet
}

/// The open requests now and as they change.
pub fn subscribe() -> watch::Receiver<Vec<Request>> {
    open_sender().subscribe()
}

/// Pushes each new open request once, until the process stops.
pub async fn run(reporter: Reporter) {
    let mut pushed = Pushed::load(Some(crate::config::default_state_dir().join("needs-you-pushed.json")));
    let mut open = subscribe();
    loop {
        let current = open.borrow_and_update().clone();
        for event in pushed.pushes(&current) {
            reporter.send(event);
        }
        if open.changed().await.is_err() {
            return;
        }
    }
}

/// The `needs-you` service: `{"items":[...]}` now and on each change, until the phone closes it.
pub async fn serve(sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    let mut open = subscribe();
    loop {
        let message = serde_json::json!({ "items": *open.borrow_and_update() });
        if sender.send(Bytes::from(message.to_string())).await.is_err() {
            return Ok(());
        }
        loop {
            tokio::select! {
                changed = open.changed() => {
                    if changed.is_err() {
                        return Ok(());
                    }
                    break;
                }
                event = receiver.recv() => match event {
                    // Nothing to read from the phone; it only closes.
                    Some(ChannelEvent::Data(_)) => {}
                    Some(ChannelEvent::Closed(_)) | None => return Ok(()),
                },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str) -> Request {
        Request {
            id: id.into(),
            title: format!("Held for your trial: {id}"),
            body: "manaflow-ai/cmux#33705".into(),
            kind: "review".into(),
            source: "GitHub".into(),
            url: Some("https://github.com/manaflow-ai/cmux/pull/33705".into()),
            created_at_ms: 1,
        }
    }

    #[test]
    fn each_request_pushes_once_as_an_ask() {
        let mut pushed = Pushed::load(None);
        let first = pushed.pushes(&[request("fi_a")]);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].event_id, "feed-fi_a");
        assert_eq!(first[0].kind, "question");
        assert_eq!(first[0].agent.as_deref(), Some("GitHub"));
        assert_eq!(first[0].title.as_deref(), Some("Held for your trial: fi_a"));
        assert_eq!(first[0].state.as_deref(), Some("waiting"));
        // The same set again (a re-sent set, a re-watch): nothing.
        assert!(pushed.pushes(&[request("fi_a")]).is_empty());
        // A second request is new; the first is not.
        let next = pushed.pushes(&[request("fi_a"), request("fi_b")]);
        assert_eq!(next.iter().map(|e| e.event_id.as_str()).collect::<Vec<_>>(), ["feed-fi_b"]);
        // Closed, then open again: not new.
        assert!(pushed.pushes(&[]).is_empty());
        assert!(pushed.pushes(&[request("fi_a")]).is_empty());
    }

    #[test]
    fn a_restart_never_pushes_a_request_again() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("needs-you-pushed.json");
        let mut before = Pushed::load(Some(path.clone()));
        assert_eq!(before.pushes(&[request("fi_a")]).len(), 1);
        // The app (and its hostd) start again and send the same open set.
        let mut after = Pushed::load(Some(path));
        assert!(after.pushes(&[request("fi_a")]).is_empty());
        assert_eq!(after.pushes(&[request("fi_a"), request("fi_c")]).len(), 1);
    }

    #[test]
    fn an_open_request_is_never_forgotten() {
        let mut pushed = Pushed::load(None);
        let open = request("fi_open");
        assert_eq!(pushed.pushes(&[open.clone()]).len(), 1);
        for n in 0..PUSHED_LIMIT + 10 {
            pushed.pushes(&[open.clone(), request(&format!("fi_{n}"))]);
        }
        assert!(pushed.pushes(&[open]).is_empty());
        assert!(pushed.order.len() <= PUSHED_LIMIT);
    }

    #[test]
    fn sanitize_keeps_only_what_is_safe_to_serve() {
        let mut bad_id = request("fi a/b");
        bad_id.title = "x".into();
        let mut untitled = request("fi_untitled");
        untitled.title = "  ".into();
        let mut plain_link = request("fi_http");
        plain_link.url = Some("javascript:alert(1)".into());
        let items = sanitize(vec![request("fi_a"), request("fi_a"), bad_id, untitled, plain_link]);
        assert_eq!(items.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["fi_a", "fi_http"]);
        assert_eq!(items[1].url, None);
        assert_eq!(sanitize((0..100).map(|n| request(&format!("fi_{n}"))).collect()).len(), MAX_ITEMS);
    }

    #[tokio::test]
    async fn the_set_reaches_subscribers_only_when_it_changes() {
        let mut open = subscribe();
        open.borrow_and_update();
        set(vec![request("fi_watch")]);
        assert!(open.has_changed().unwrap());
        assert_eq!(open.borrow_and_update().iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["fi_watch"]);
        set(vec![request("fi_watch")]);
        assert!(!open.has_changed().unwrap());
        set(Vec::new());
        assert!(open.borrow_and_update().is_empty());
    }
}
