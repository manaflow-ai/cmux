//! The one network read of the catalog: an HTTPS GET of a fixed URL with
//! If-None-Match, no redirects, a timeout, and a body cap.

use futures::future::BoxFuture;

use super::schema::MAX_BODY_BYTES;

/// Where release builds read the catalog.
pub const CATALOG_URL: &str = "https://cmux.com/api/models/v1";
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

/// The catalog URL for this build: [`CATALOG_URL`], or in a dev build an https
/// `ACPMUX_CATALOG_URL`. A release build ignores the variable.
pub fn catalog_url(debug_build: bool, override_url: Option<&str>) -> String {
    match override_url {
        Some(url)
            if debug_build && url.starts_with("https://") && reqwest::Url::parse(url).is_ok() =>
        {
            url.to_owned()
        }
        _ => CATALOG_URL.to_owned(),
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

pub struct HttpsFetcher {
    url: String,
}

impl HttpsFetcher {
    pub fn new(url: String) -> Self {
        Self { url }
    }

    /// The fetcher for this build and environment.
    pub fn current() -> Self {
        let env = std::env::var(URL_OVERRIDE_ENV).ok();
        Self::new(catalog_url(cfg!(debug_assertions), env.as_deref()))
    }

    async fn get(&self, etag: Option<&str>) -> Result<FetchOutcome, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(TIMEOUT)
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        let mut request = client.get(&self.url).header("Accept", "application/json");
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
