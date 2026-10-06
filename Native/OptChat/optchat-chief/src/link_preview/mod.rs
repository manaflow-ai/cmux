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

use guard::{HttpTransport, Transport};

/// Longest fetch of one preview: the page, then its image.
pub const TIMEOUT: Duration = Duration::from_secs(8);

/// One fetched preview.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fetched {
    pub title: Option<String>,
    pub site: Option<String>,
    pub picture: Option<picture::Picture>,
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
        // Not yet: page and image.
        let _ = (url, deadline, &self.transport);
        None
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
    // Not yet: the concurrent fetch.
    let _ = (fetcher, urls, timeout, channel::<()>);
    Vec::new()
}
