//! The model catalog document (`GET /api/models/v1`, `schemaVersion` 1, the
//! M2 shape `{schemaVersion, generatedAt, source, harnesses, models,
//! providers}`) and its strict check; `web/services/model-catalog/schema.ts`
//! applies the same rules. Data only: nothing in it is run, and the only URL
//! field (`docsUrl`) is kept only when it is https on [`DOCS_URL_HOSTS`].
//!
//! `schemaVersion` is the major version. A higher one is refused as
//! [`CatalogError::UnsupportedVersion`] so the caller keeps its current copy.
//! Fields a version-1 server adds later are ignored; a known field of the
//! wrong type refuses the whole document.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The schema major version this build reads.
pub const SCHEMA_VERSION: u64 = 1;
/// The largest catalog body read, in bytes.
pub const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;
const MAX_HARNESSES: usize = 64;
const MAX_MODELS: usize = 2_000;
const MAX_TEXT: usize = 200;
const EFFORTS: &[&str] = &["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const STATUSES: &[&str] = &["preview", "deprecated"];

/// Hosts a harness's `docsUrl` may point at. Any other URL is dropped.
pub const DOCS_URL_HOSTS: &[&str] = &[
    "aider.chat",
    "cmux.com",
    "developers.openai.com",
    "docs.anthropic.com",
    "docs.claude.com",
    "github.com",
    "opencode.ai",
    "vercel.com",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub schema_version: u64,
    /// When the server built it (ISO-8601).
    pub generated_at: String,
    /// `live` (from models.dev) or `snapshot` (the bundled copy).
    pub source: String,
    pub harnesses: Vec<CatalogHarness>,
    /// Model metadata by `<provider>/<model id>`.
    #[serde(default)]
    pub models: BTreeMap<String, ModelInfo>,
    #[serde(default)]
    pub providers: BTreeMap<String, ProviderInfo>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogHarness {
    pub id: String,
    pub name: String,
    pub brand: String,
    /// acpmux harness families this entry describes.
    pub families: Vec<String>,
    /// `catalog`: the models below are the list; `probe`: the harness reports its own.
    pub model_source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docs_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
    pub models: Vec<HarnessModel>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessModel {
    /// The id the harness takes (`--model`, ACP `session/set_model`).
    pub id: String,
    /// Its `models` key.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
    pub name: String,
    pub short_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub efforts: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aliases: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cost {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub knowledge: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_weights: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<Cost>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderInfo {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error("the catalog body is {0} bytes, above the {MAX_BODY_BYTES} byte limit")]
    Oversize(usize),
    #[error("the catalog uses schema version {0}; this build reads version {SCHEMA_VERSION}")]
    UnsupportedVersion(u64),
    #[error("the catalog is not valid: {0}")]
    Invalid(String),
}

fn invalid(message: impl Into<String>) -> CatalogError {
    CatalogError::Invalid(message.into())
}

fn id_ok(id: &str) -> bool {
    let mut chars = id.chars();
    id.len() <= MAX_TEXT
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || "._:/@[]+-".contains(c))
}

fn slug_ok(id: &str) -> bool {
    id.len() <= 64
        && id.chars().next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn text_ok(text: &str) -> bool {
    !text.trim().is_empty() && text.chars().count() <= MAX_TEXT
}

fn ensure(ok: bool, message: impl FnOnce() -> String) -> Result<(), CatalogError> {
    if ok { Ok(()) } else { Err(invalid(message())) }
}

/// An https URL on [`DOCS_URL_HOSTS`], without credentials or a port. Anything else is not followed.
pub fn allowed_docs_url(raw: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(raw) else { return false };
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url.host_str().is_some_and(|host| DOCS_URL_HOSTS.contains(&host))
}

fn check_model(harness: &str, model: &HarnessModel) -> Result<(), CatalogError> {
    let id = &model.id;
    ensure(id_ok(id) && model.reference.as_deref().is_none_or(id_ok), || {
        format!("harness {harness}: model id {id:?} or its ref is malformed")
    })?;
    ensure(text_ok(&model.name) && text_ok(&model.short_name), || {
        format!("harness {harness}: model {id} has an empty or long name")
    })?;
    ensure(model.provider.as_deref().is_none_or(slug_ok), || {
        format!("harness {harness}: model {id} has a malformed provider")
    })?;
    let efforts = model.efforts.as_deref().unwrap_or_default();
    ensure(efforts.iter().all(|e| EFFORTS.contains(&e.as_str())), || {
        format!("harness {harness}: model {id} has an unknown effort")
    })?;
    ensure(model.default_effort.as_ref().is_none_or(|e| efforts.contains(e)), || {
        format!("harness {harness}: model {id} defaultEffort is not one of its efforts")
    })?;
    ensure(model.aliases.as_deref().unwrap_or_default().iter().all(|a| id_ok(a)), || {
        format!("harness {harness}: model {id} has a malformed alias")
    })?;
    ensure(model.status.as_deref().is_none_or(|s| STATUSES.contains(&s)), || {
        format!("harness {harness}: model {id} has an unknown status")
    })
}

fn check_harness(harness: &CatalogHarness) -> Result<(), CatalogError> {
    let id = &harness.id;
    ensure(slug_ok(id) && text_ok(&harness.name) && slug_ok(&harness.brand), || {
        format!("harness id {id:?}, its name or its brand is malformed")
    })?;
    ensure(harness.families.iter().all(|f| slug_ok(f)), || {
        format!("harness {id} has a malformed family")
    })?;
    ensure(matches!(harness.model_source.as_str(), "catalog" | "probe"), || {
        format!("harness {id} modelSource must be catalog or probe")
    })?;
    ensure(harness.models.len() <= MAX_MODELS, || {
        format!("harness {id} has more than {MAX_MODELS} models")
    })?;
    let mut seen = HashSet::new();
    for model in &harness.models {
        check_model(id, model)?;
        ensure(seen.insert(model.id.as_str()), || {
            format!("harness {id} lists model {} twice", model.id)
        })?;
    }
    ensure(harness.default_model.as_ref().is_none_or(|d| seen.contains(d.as_str())), || {
        format!("harness {id} defaultModel is not one of its models")
    })
}

fn check_info(reference: &str, info: &ModelInfo) -> Result<(), CatalogError> {
    ensure(id_ok(reference) && text_ok(&info.name), || {
        format!("models[{reference:?}] is malformed")
    })?;
    ensure(info.status.as_deref().is_none_or(|s| STATUSES.contains(&s)), || {
        format!("models[{reference:?}] has an unknown status")
    })?;
    let prices = info
        .cost
        .as_ref()
        .map(|c| [c.input, c.output, c.cache_read, c.cache_write])
        .unwrap_or_default();
    ensure(prices.iter().flatten().all(|p| p.is_finite() && *p >= 0.0), || {
        format!("models[{reference:?}] has a negative price")
    })
}

/// Drops what a client must not follow: a docs URL off the allowlist.
fn sanitize(catalog: &mut Catalog) {
    for harness in &mut catalog.harnesses {
        if harness.docs_url.as_deref().is_some_and(|url| !allowed_docs_url(url)) {
            tracing::warn!(harness = %harness.id, "model catalog: docsUrl is not on the allowlist; ignored");
            harness.docs_url = None;
        }
    }
}

/// Reads and checks one catalog body.
pub fn parse(body: &[u8]) -> Result<Catalog, CatalogError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(CatalogError::Oversize(body.len()));
    }
    let value: Value = serde_json::from_slice(body).map_err(|e| invalid(e.to_string()))?;
    // The version first: a newer major version may change any other field.
    match value.get("schemaVersion").and_then(Value::as_u64) {
        Some(SCHEMA_VERSION) => {}
        Some(v) if v > SCHEMA_VERSION => return Err(CatalogError::UnsupportedVersion(v)),
        _ => return Err(invalid("schemaVersion must be the integer 1")),
    }
    let mut catalog: Catalog = serde_json::from_value(value).map_err(|e| invalid(e.to_string()))?;
    let date = catalog.generated_at.as_bytes();
    ensure(date.len() >= 11 && date.len() <= 40 && date[4] == b'-' && date[10] == b'T', || {
        "generatedAt must be an ISO-8601 timestamp".into()
    })?;
    ensure(matches!(catalog.source.as_str(), "live" | "snapshot"), || {
        "source must be live or snapshot".into()
    })?;
    ensure(!catalog.harnesses.is_empty() && catalog.harnesses.len() <= MAX_HARNESSES, || {
        format!("harnesses must have 1 to {MAX_HARNESSES} entries")
    })?;
    let mut seen = HashSet::new();
    for harness in &catalog.harnesses {
        check_harness(harness)?;
        ensure(seen.insert(harness.id.as_str()), || {
            format!("harness {} is listed twice", harness.id)
        })?;
    }
    for (reference, info) in &catalog.models {
        check_info(reference, info)?;
    }
    ensure(catalog.providers.iter().all(|(id, p)| slug_ok(id) && text_ok(&p.name)), || {
        "a provider is malformed".into()
    })?;
    sanitize(&mut catalog);
    Ok(catalog)
}
