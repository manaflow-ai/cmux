//! A dev build's cloud data space: `X-Cmux-Build-Space: dev:<slug>`.
//!
//! A dev build sends its tag on every request and WebSocket upgrade to the
//! backend, so dev builds never see each other's data or the data of nightly
//! and stable builds. Nightly, stable and store builds have no build space
//! and send no header at all. The app decides (Swift `CMUXBuildSpace`); this
//! crate only checks the value's form and sends it.

/// The request header the backends read.
pub const HEADER: &str = "x-cmux-build-space";

/// The longest slug the backends accept.
const MAX_SLUG: usize = 64;

/// A valid build space value (`dev:<slug>`, the backends' pattern
/// `^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BuildSpace(String);

impl BuildSpace {
    /// `value` when it matches the backends' pattern; `None` otherwise (an
    /// empty, malformed or too-long value sends no header rather than one the
    /// backend refuses).
    pub fn parse(value: &str) -> Option<Self> {
        let slug = value.strip_prefix("dev:")?;
        let bytes = slug.as_bytes();
        let edge = |b: &u8| b.is_ascii_lowercase() || b.is_ascii_digit();
        let valid = !bytes.is_empty()
            && bytes.len() <= MAX_SLUG
            && bytes.first().is_some_and(edge)
            && bytes.last().is_some_and(edge)
            && bytes.iter().all(|b| edge(b) || *b == b'-');
        valid.then(|| Self(value.to_owned()))
    }

    /// [`Self::parse`] of an optional value (an unset or blank variable is no space).
    pub fn parse_optional(value: Option<&str>) -> Option<Self> {
        value.map(str::trim).filter(|v| !v.is_empty()).and_then(Self::parse)
    }

    /// The header value, `dev:<slug>`.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for BuildSpace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
