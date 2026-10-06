//! iMessage-style link previews on the Chief's replies. The SENDER makes the
//! preview and receivers never fetch (cmux-conversation `link_preview`): a
//! reply line that is only an http(s) URL becomes a `link_preview` part in
//! its place ([`split`]), and the host fetches that page's title, site and
//! image through the SSRF guard ([`guard`]), parses them ([`meta`]), turns
//! the image into a small JPEG ([`picture`]) and uploads it as an ordinary
//! attachment record of the conversation (the brain's `previews`). A fetch
//! that fails or runs out of time leaves the card with its URL only, as
//! Messages sends it.

pub mod guard;
pub mod meta;
pub mod picture;
pub mod split;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use guard::{HttpTransport, Kind, Transport, guarded_get};
use picture::Picture;

/// Longest fetch of one preview: the page, then its image.
pub const TIMEOUT: Duration = Duration::from_secs(8);

/// One fetched preview.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fetched {
    pub title: Option<String>,
    pub site: Option<String>,
    pub picture: Option<Picture>,
}

/// Fetches the preview of one URL by `deadline` (None: no preview).
pub trait Fetcher: Send + Sync {
    fn fetch(&self, url: &str, deadline: Instant) -> Option<Fetched>;
}

/// The network fetcher: page and image through the guard.
pub struct HttpFetcher {
    transport: Arc<dyn Transport>,
}

impl Default for HttpFetcher {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpFetcher {
    pub fn new() -> HttpFetcher {
        HttpFetcher::with_transport(Arc::new(HttpTransport::new()))
    }

    pub fn with_transport(transport: Arc<dyn Transport>) -> HttpFetcher {
        HttpFetcher { transport }
    }
}

impl Fetcher for HttpFetcher {
    fn fetch(&self, url: &str, deadline: Instant) -> Option<Fetched> {
        let (page, body) = guarded_get(&*self.transport, url, Kind::Html, deadline).ok()?;
        let html = String::from_utf8_lossy(&body);
        let meta = meta::page_meta(&html, &page);
        let picture = meta.image.and_then(|image| {
            let (_, bytes) =
                guarded_get(&*self.transport, image.as_str(), Kind::Image, deadline).ok()?;
            picture::to_jpeg(&bytes)
        });
        Some(Fetched {
            title: meta.title,
            site: meta.site,
            picture,
        })
    }
}

/// Fetches every `(part index, URL)` at once, each by `timeout` from now,
/// and returns the previews that arrived in time. A fetch still running
/// at the deadline is left to end on its own (its transport has the same
/// deadline); its card keeps the URL only.
pub fn fetch_all(
    fetcher: Arc<dyn Fetcher>,
    urls: Vec<(usize, String)>,
    timeout: Duration,
) -> Vec<(usize, Fetched)> {
    let deadline = Instant::now() + timeout;
    let (tx, rx) = channel();
    let mut started = 0;
    for (index, url) in urls {
        let (fetcher, tx) = (fetcher.clone(), tx.clone());
        let spawned = std::thread::Builder::new()
            .name("optchat-link-preview".into())
            .spawn(move || {
                let _ = tx.send((index, fetcher.fetch(&url, deadline)));
            });
        if spawned.is_ok() {
            started += 1;
        }
    }
    drop(tx);
    let mut out = Vec::new();
    for _ in 0..started {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok((index, Some(fetched))) => out.push((index, fetched)),
            Ok((_, None)) => {}
            Err(_) => break,
        }
    }
    out.sort_by_key(|(index, _)| *index);
    out
}
