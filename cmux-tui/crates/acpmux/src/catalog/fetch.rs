//! The one network read of the catalog: an HTTPS GET of a fixed URL with
//! If-None-Match, no redirects, a timeout, and a body cap.

use futures::future::BoxFuture;

use super::schema::MAX_BODY_BYTES;

/// Where release builds read the catalog: the live models backend (cmux-api, deployed from
/// feat-cmux-next). cmux.com deploys from main and has answered 404 here (2026-11-19).
pub const CATALOG_URL: &str = "https://cloud-api.cmux.dev/v1/models/catalog";
/// Read when [`CATALOG_URL`] fails: the same document from the web app.
pub const FALLBACK_CATALOG_URL: &str = "https://cmux.com/api/models/v1";
/// A dev build (debug assertions on) may read another https URL, for example the dev backend.
pub const URL_OVERRIDE_ENV: &str = "ACPMUX_CATALOG_URL";
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// What one fetch answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchOutcome {
    /// 304: the copy with this ETag is current.
    NotModified,
    Body {
        body: Vec<u8>,
        etag: Option<String>,
    },
}

/// Reads the catalog. The daemon uses [`HttpsFetcher`]; tests pass fakes.
pub trait Fetcher: Send + Sync {
    fn fetch<'a>(&'a self, etag: Option<&'a str>) -> BoxFuture<'a, Result<FetchOutcome, String>>;
}

/// The URLs a fetch tries in order: [`CATALOG_URL`] then [`FALLBACK_CATALOG_URL`], or only a dev
/// build's https `ACPMUX_CATALOG_URL`. A release build ignores the variable.
pub fn catalog_urls(debug_build: bool, override_url: Option<&str>) -> Vec<String> {
    match override_url {
        Some(url)
            if debug_build && url.starts_with("https://") && reqwest::Url::parse(url).is_ok() =>
        {
            vec![url.to_owned()]
        }
        _ => vec![CATALOG_URL.to_owned(), FALLBACK_CATALOG_URL.to_owned()],
    }
}

/// Appends `chunk` unless the body would pass `max` bytes.
pub fn push_capped(body: &mut Vec<u8>, chunk: &[u8], max: usize) -> Result<(), String> {
    if body.len() + chunk.len() > max {
        return Err(format!("the catalog body is above the {max} byte limit"));
    }
    body.extend_from_slice(chunk);
    Ok(())
}

/// Reads the catalog over https from each of its URLs in turn, until one answers.
pub struct HttpsFetcher {
    urls: Vec<String>,
}

impl HttpsFetcher {
    pub fn new(url: String) -> Self {
        Self { urls: vec![url] }
    }

    /// The fetcher for this build and environment.
    pub fn current() -> Self {
        let env = std::env::var(URL_OVERRIDE_ENV).ok();
        Self { urls: catalog_urls(cfg!(debug_assertions), env.as_deref()) }
    }

    async fn get(&self, etag: Option<&str>) -> Result<FetchOutcome, String> {
        let mut errors = Vec::new();
        for url in &self.urls {
            match self.get_one(url, etag).await {
                Ok(outcome) => return Ok(outcome),
                Err(e) => errors.push(e),
            }
        }
        Err(errors.join("; then "))
    }

    async fn get_one(&self, url: &str, etag: Option<&str>) -> Result<FetchOutcome, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = crate::happy_dial::http_client()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(TIMEOUT)
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        let mut request = client.get(url).header("Accept", "application/json");
        if let Some(etag) = etag {
            request = request.header("If-None-Match", etag);
        }
        let mut response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        if status == 304 {
            return Ok(FetchOutcome::NotModified);
        }
        if status != 200 {
            return Err(format!("the catalog server answered {status}"));
        }
        if response.content_length().is_some_and(|n| n > MAX_BODY_BYTES as u64) {
            return Err(format!("the catalog body is above the {MAX_BODY_BYTES} byte limit"));
        }
        let etag = response.headers().get("etag").and_then(|v| v.to_str().ok()).map(str::to_owned);
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
            push_capped(&mut body, &chunk, MAX_BODY_BYTES)?;
        }
        Ok(FetchOutcome::Body { body, etag })
    }
}

impl Fetcher for HttpsFetcher {
    fn fetch<'a>(&'a self, etag: Option<&'a str>) -> BoxFuture<'a, Result<FetchOutcome, String>> {
        Box::pin(self.get(etag))
    }
}
