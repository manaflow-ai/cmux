//! The public model feed read directly (models.dev, the source the cmux catalog
//! server projects), so a model reaches the pickers the day the feed lists it:
//! before the catalog is rebuilt, and while the catalog server is down or
//! answers 404 (the cmux.com deploy had no `/api/models/v1` route, 2026-11-19:
//! "gemini neon didn't automatically appear in model picker for us").
//!
//! The catalog in use keeps every field it has; the feed only adds the models a
//! `catalog` harness's rules (`CatalogHarness::feed`, from
//! `web/services/model-catalog/overrides.ts`) select and the catalog lacks,
//! newest first, with their metadata. A catalog without rules is unchanged.
//!
//! Cost: one conditional GET an hour (`If-None-Match`; models.dev answers 304
//! with no body when nothing changed, else about 0.7 MB gzip). The 5 MB body is
//! parsed off the async runtime and dropped; only the models of the providers
//! the rules name are kept (a few hundred small rows), and the other providers'
//! models are skipped as they stream past, never built as a tree.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;

use futures::future::BoxFuture;
use serde::Deserialize;
use serde::de::IgnoredAny;
use serde_json::Value;

use super::fetch::{FetchOutcome, Fetcher};
use super::schema::{self, Catalog, Cost, FeedSource, HarnessFeed, HarnessModel, ModelInfo};

/// The public feed the catalog server projects.
pub const FEED_URL: &str = "https://models.dev/api.json";
/// The largest feed body read off the wire (gzip), in bytes. models.dev sends about 0.7 MB.
pub const MAX_WIRE_BYTES: usize = 16 * 1024 * 1024;
/// The largest decoded feed, in bytes. models.dev's file is about 5 MB.
pub const MAX_FEED_BYTES: usize = 48 * 1024 * 1024;
/// At most this many models join one harness from the feed.
const MAX_ADDED: usize = 200;
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const EFFORTS: &[&str] = &["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// One feed model, reduced to what a catalog row and its metadata use.
#[derive(Debug, Clone, PartialEq)]
pub struct FeedModel {
    pub id: String,
    pub name: String,
    pub family: Option<String>,
    pub release_date: Option<String>,
    pub tool_call: Option<bool>,
    pub efforts: Vec<String>,
    pub fast: bool,
    pub status: Option<String>,
    pub info: ModelInfo,
}

/// The kept part of one feed read: every provider's name, and the models of the
/// providers the rules name.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FeedSnapshot {
    names: BTreeMap<String, String>,
    models: BTreeMap<String, Vec<FeedModel>>,
}

impl FeedSnapshot {
    /// Whether this read kept `provider`'s models (a rule named it when it was parsed).
    pub fn has_models_of(&self, provider: &str) -> bool {
        self.models.contains_key(provider)
    }

    /// Whether every provider `providers` names was kept.
    pub fn covers(&self, providers: &BTreeSet<String>) -> bool {
        providers.iter().all(|p| self.models.contains_key(p))
    }
}

/// The providers whose models `catalog`'s feed rules select.
pub fn providers_used(catalog: &Catalog) -> BTreeSet<String> {
    catalog
        .harnesses
        .iter()
        .filter(|h| h.model_source == "catalog")
        .filter_map(|h| h.feed.as_ref())
        .flat_map(|f| f.sources.iter().map(|s| s.provider.clone()))
        .collect()
}

#[derive(Deserialize)]
struct RawProvider {
    #[serde(default)]
    name: Value,
    #[serde(default)]
    models: Value,
}

/// Reads one feed body (models.dev's `{provider: {name, models: {id: model}}}`), keeping the
/// models of `keep`. A malformed model is skipped; only a body that is not that object fails.
///
/// The body streams through a typed visitor: a provider outside `keep` keeps its name only and
/// its models are skipped unbuilt (`IgnoredAny`), so the 5 MB file never becomes a `Value` tree
/// (that tree was several times the body, at startup and on each hourly refresh, and took 166 ms
/// to build where the streamed read takes 6 ms). A kept provider is read
/// as before, so the snapshot is the same (`feed_tests.rs` compares both on fixtures).
pub fn parse(body: &[u8], keep: &BTreeSet<String>) -> Result<FeedSnapshot, String> {
    let mut de = serde_json::Deserializer::from_slice(body);
    let raw = serde::de::DeserializeSeed::deserialize(Providers { keep }, &mut de)
        .and_then(|raw| de.end().map(|()| raw))
        .map_err(|e| format!("the model feed is not an object: {e}"))?;
    Ok(snapshot(raw, keep))
}

/// The kept part of the providers read, in the order and with the fallbacks `parse` always had.
fn snapshot(raw: BTreeMap<String, Option<RawProvider>>, keep: &BTreeSet<String>) -> FeedSnapshot {
    let mut snapshot = FeedSnapshot::default();
    for (id, provider) in raw {
        let Some(provider) = provider else { continue };
        snapshot.names.insert(id.clone(), text(&provider.name).unwrap_or_else(|| id.clone()));
        if !keep.contains(&id) {
            continue;
        }
        let models = match provider.models {
            Value::Object(models) => models.into_values().filter_map(feed_model).collect(),
            _ => Vec::new(),
        };
        snapshot.models.insert(id, models);
    }
    snapshot
}

/// The feed's top-level map: each provider read whole when `keep` names it, else its name only.
/// A later duplicate key replaces an earlier one, as a map read does.
struct Providers<'a> {
    keep: &'a BTreeSet<String>,
}

impl<'de> serde::de::DeserializeSeed<'de> for Providers<'_> {
    type Value = BTreeMap<String, Option<RawProvider>>;

    fn deserialize<D: serde::Deserializer<'de>>(self, de: D) -> Result<Self::Value, D::Error> {
        de.deserialize_map(self)
    }
}

impl<'de> serde::de::Visitor<'de> for Providers<'_> {
    type Value = BTreeMap<String, Option<RawProvider>>;

    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a map of providers")
    }

    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut raw = BTreeMap::new();
        while let Some(id) = map.next_key::<String>()? {
            let provider = if self.keep.contains(&id) {
                RawProvider::deserialize(map.next_value::<Value>()?).ok()
            } else {
                map.next_value::<NameOnly>()?
                    .0
                    .map(|name| RawProvider { name, models: Value::Null })
            };
            raw.insert(id, provider);
        }
        Ok(raw)
    }
}

/// A provider outside `keep`: its `name`, everything else skipped as it streams past. `None`
/// where reading it as [`RawProvider`] would fail (not an object, an array past two items), so
/// the provider is skipped as before. Never an error on well-formed JSON.
struct NameOnly(Option<Value>);

impl<'de> Deserialize<'de> for NameOnly {
    fn deserialize<D: serde::Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        de.deserialize_any(NameOnlyVisitor)
    }
}

struct NameOnlyVisitor;

impl<'de> serde::de::Visitor<'de> for NameOnlyVisitor {
    type Value = NameOnly;

    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a provider")
    }

    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<NameOnly, A::Error> {
        let mut name = Value::Null;
        while let Some(key) = map.next_key::<std::borrow::Cow<'de, str>>()? {
            if key == "name" {
                name = map.next_value()?;
            } else {
                map.next_value::<IgnoredAny>()?;
            }
        }
        Ok(NameOnly(Some(name)))
    }

    // A derived struct reads an array as its fields in order: `[name, models]`.
    fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<NameOnly, A::Error> {
        let name = seq.next_element::<Value>()?;
        let _models = seq.next_element::<IgnoredAny>()?;
        let mut extra = false;
        while seq.next_element::<IgnoredAny>()?.is_some() {
            extra = true;
        }
        Ok(NameOnly((!extra).then(|| name.unwrap_or(Value::Null))))
    }

    fn visit_bool<E>(self, _: bool) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
    fn visit_i64<E>(self, _: i64) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
    fn visit_u64<E>(self, _: u64) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
    fn visit_f64<E>(self, _: f64) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
    fn visit_str<E>(self, _: &str) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
    fn visit_unit<E>(self) -> Result<NameOnly, E> {
        Ok(NameOnly(None))
    }
}

/// The read `parse` replaced, kept as the reference its tests compare against: the whole body as
/// a `Value` tree first, then the providers `keep` names.
#[cfg(test)]
pub(crate) fn parse_tree(body: &[u8], keep: &BTreeSet<String>) -> Result<FeedSnapshot, String> {
    let raw: BTreeMap<String, Value> = serde_json::from_slice(body)
        .map_err(|e| format!("the model feed is not an object: {e}"))?;
    let raw =
        raw.into_iter().map(|(id, value)| (id, RawProvider::deserialize(value).ok())).collect();
    Ok(snapshot(raw, keep))
}

fn feed_model(raw: Value) -> Option<FeedModel> {
    let Value::Object(m) = raw else { return None };
    let id = text(m.get("id")?)?;
    let name = clean_name(&text(m.get("name")?)?);
    let family = m.get("family").and_then(text);
    let release_date = m.get("release_date").and_then(text);
    let efforts = m
        .get("reasoning_options")
        .and_then(Value::as_array)
        .and_then(|options| options.iter().find(|o| o.get("type") == Some(&Value::from("effort"))))
        .and_then(|o| o.get("values"))
        .and_then(Value::as_array)
        .map(|values| {
            EFFORTS
                .iter()
                .filter(|e| values.iter().any(|v| v.as_str() == Some(**e)))
                .map(|e| (*e).to_owned())
                .collect()
        })
        .unwrap_or_default();
    let fast = m
        .get("experimental")
        .and_then(|x| x.get("modes"))
        .and_then(|x| x.get("fast"))
        .is_some_and(Value::is_object);
    let status = match m.get("status").and_then(Value::as_str) {
        Some("deprecated") => Some("deprecated".to_owned()),
        Some("beta" | "alpha" | "preview") => Some("preview".to_owned()),
        _ => None,
    };
    let limit = m.get("limit");
    let positive = |v: Option<&Value>| v.and_then(Value::as_u64).filter(|n| *n > 0);
    let input: Vec<String> = m
        .get("modalities")
        .and_then(|x| x.get("input"))
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .filter(|v| ["text", "image", "pdf", "audio", "video"].contains(v))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let price = |key: &str| {
        m.get("cost")
            .and_then(|c| c.get(key))
            .and_then(Value::as_f64)
            .filter(|p| p.is_finite() && *p >= 0.0)
    };
    let cost = Cost {
        input: price("input"),
        output: price("output"),
        cache_read: price("cache_read"),
        cache_write: price("cache_write"),
    };
    let has_cost = cost.input.is_some()
        || cost.output.is_some()
        || cost.cache_read.is_some()
        || cost.cache_write.is_some();
    let info = ModelInfo {
        name: name.clone(),
        family: family.clone(),
        release_date: release_date.clone(),
        knowledge: m.get("knowledge").and_then(text),
        context_window: positive(limit.and_then(|l| l.get("context"))),
        max_output: positive(limit.and_then(|l| l.get("output"))),
        input: (!input.is_empty()).then_some(input),
        reasoning: m.get("reasoning").and_then(Value::as_bool),
        tool_call: m.get("tool_call").and_then(Value::as_bool),
        open_weights: m.get("open_weights").and_then(Value::as_bool),
        cost: has_cost.then_some(cost),
        status: status.clone(),
    };
    Some(FeedModel {
        tool_call: m.get("tool_call").and_then(Value::as_bool),
        id,
        name,
        family,
        release_date,
        efforts,
        fast,
        status,
        info,
    })
}

/// `base` with the feed models its harnesses' rules select and it lacks, as the server's
/// projection (`project.ts`) names them, newest first ahead of the harness's own rows.
/// Drops every model row marked `disabled` from `catalog`, after the feed overlay (which saw the
/// rows, so it never adds them back). Their ids go to [`schema::CatalogHarness::disabled`]; a default
/// model that is disabled is cleared.
pub fn drop_disabled(catalog: &mut Catalog) {
    for harness in &mut catalog.harnesses {
        let (off, on): (Vec<_>, Vec<_>) = std::mem::take(&mut harness.models)
            .into_iter()
            .partition(|m| m.status.as_deref() == Some("disabled"));
        harness.models = on;
        harness.disabled = off.into_iter().map(|m| m.id).collect();
        if harness.default_model.as_ref().is_some_and(|d| harness.disabled.contains(d)) {
            harness.default_model = None;
        }
    }
}

pub fn overlay(base: &Catalog, feed: &FeedSnapshot) -> Catalog {
    let mut out = base.clone();
    for harness in &mut out.harnesses {
        let Some(rules) = harness.feed.clone().filter(|_| harness.model_source == "catalog") else {
            continue;
        };
        let mut added: Vec<(Option<String>, HarnessModel, String, ModelInfo)> = Vec::new();
        for source in &rules.sources {
            for model in feed.models.get(&source.provider).into_iter().flatten() {
                let listed = harness.models.iter().any(|m| m.id == model.id)
                    || added.iter().any(|(_, m, _, _)| m.id == model.id);
                if listed || !selected(model, source, &rules) {
                    continue;
                }
                let row = harness_model(model, &source.provider, &rules, feed);
                if schema::check_model(&harness.id, &row).is_err() {
                    continue;
                }
                let reference = format!("{}/{}", source.provider, model.id);
                if schema::check_info(&reference, &model.info).is_err() {
                    continue;
                }
                added.push((model.release_date.clone(), row, reference, model.info.clone()));
            }
        }
        if added.is_empty() {
            continue;
        }
        // Newest first; the feed's key order is not stable, so ties go by id.
        added.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
        added.truncate(MAX_ADDED);
        let mut rows = Vec::with_capacity(added.len() + harness.models.len());
        for (_, row, reference, info) in added {
            out.models.entry(reference).or_insert(info);
            rows.push(row);
        }
        rows.append(&mut harness.models);
        harness.models = rows;
    }
    let used = providers_used(base);
    for (id, name) in &feed.names {
        if used.contains(id) {
            out.providers.entry(id.clone()).or_insert(schema::ProviderInfo { name: name.clone() });
        }
    }
    out
}

fn selected(model: &FeedModel, source: &FeedSource, rules: &HarnessFeed) -> bool {
    if model.tool_call == Some(false) {
        return false;
    }
    if rules.hidden.as_deref().unwrap_or_default().contains(&model.id) {
        return false;
    }
    let included = source
        .include
        .as_deref()
        .is_none_or(|patterns| patterns.iter().any(|p| matches(&model.id, p)));
    let recent = source
        .min_release_date
        .as_deref()
        .is_none_or(|min| model.release_date.as_deref().unwrap_or("") >= min);
    let excluded =
        source.exclude.as_deref().unwrap_or_default().iter().any(|p| matches(&model.id, p));
    included && recent && !excluded
}

/// `project.ts` `matches`: `*suffix` matches the end, with `[0-9]` a digit; anything else is a prefix.
fn matches(id: &str, pattern: &str) -> bool {
    let Some(suffix) = pattern.strip_prefix('*') else { return id.starts_with(pattern) };
    let mut parts: Vec<Option<char>> = Vec::new();
    let mut rest = suffix;
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix("[0-9]") {
            parts.push(None);
            rest = after;
        } else {
            let mut chars = rest.chars();
            parts.push(Some(chars.next().unwrap_or_default()));
            rest = chars.as_str();
        }
    }
    let chars: Vec<char> = id.chars().collect();
    if parts.len() > chars.len() {
        return false;
    }
    chars[chars.len() - parts.len()..].iter().zip(&parts).all(|(c, part)| match part {
        Some(want) => c == want,
        None => c.is_ascii_digit(),
    })
}

fn harness_model(
    model: &FeedModel,
    provider: &str,
    rules: &HarnessFeed,
    feed: &FeedSnapshot,
) -> HarnessModel {
    let drop = rules.drop_efforts.as_deref().unwrap_or_default();
    let efforts: Vec<String> =
        model.efforts.iter().filter(|e| !drop.contains(*e)).cloned().collect();
    let by_provider = rules.group_by_provider == Some(true);
    // A gateway id is "<maker>/<model>": the maker is the provider a person recognizes.
    let maker = if by_provider {
        model.id.split('/').next().unwrap_or(provider).to_owned()
    } else {
        provider.to_owned()
    };
    let family = if by_provider {
        Some(feed.names.get(&maker).cloned().unwrap_or_else(|| maker.clone()))
    } else {
        model.family.as_ref().map(|f| {
            rules
                .family_names
                .as_ref()
                .and_then(|names| names.get(f))
                .cloned()
                .unwrap_or_else(|| f.clone())
        })
    };
    let short =
        rules.short_name_prefix.as_deref().and_then(|prefix| model.name.strip_prefix(prefix));
    let short_name = match short {
        Some(rest) if !rest.is_empty() => rest.to_owned(),
        _ => model.name.clone(),
    };
    let default_effort = rules.default_effort.clone().filter(|e| efforts.contains(e));
    HarnessModel {
        id: model.id.clone(),
        reference: Some(format!("{provider}/{}", model.id)),
        name: model.name.clone(),
        short_name,
        family,
        provider: Some(maker),
        efforts: (!efforts.is_empty()).then_some(efforts),
        default_effort,
        fast: model.fast.then_some(true),
        aliases: None,
        status: model.status.clone(),
    }
}

/// The feed marks moving aliases "(latest)"; pickers show the model's own name.
fn clean_name(name: &str) -> String {
    let trimmed = name.trim_end();
    let lower = trimmed.to_ascii_lowercase();
    match lower.strip_suffix("(latest)") {
        // ASCII lowercasing keeps every byte offset, so `rest.len()` is a boundary of `trimmed`.
        Some(rest) => trimmed.get(..rest.len()).unwrap_or(trimmed).trim_end().to_owned(),
        None => trimmed.to_owned(),
    }
}

fn text(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.chars().count() <= 200)
        .map(str::to_owned)
}

/// The body as sent, gunzipped when `encoding` is gzip, refused past `max` bytes decoded.
pub fn decode(body: &[u8], encoding: Option<&str>, max: usize) -> Result<Vec<u8>, String> {
    if !encoding.is_some_and(|e| e.trim().eq_ignore_ascii_case("gzip")) {
        if body.len() > max {
            return Err(format!("the model feed is above the {max} byte limit"));
        }
        return Ok(body.to_vec());
    }
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(body)
        .take(max as u64 + 1)
        .read_to_end(&mut out)
        .map_err(|e| format!("the model feed does not gunzip: {e}"))?;
    if out.len() > max {
        return Err(format!("the model feed is above the {max} byte limit"));
    }
    Ok(out)
}

/// Reads [`FEED_URL`] with `If-None-Match`, asking for gzip (decoded here, since this build's
/// HTTP client decodes none), no redirects, a timeout and size caps.
pub struct FeedFetcher {
    url: String,
}

impl Default for FeedFetcher {
    fn default() -> Self {
        Self { url: FEED_URL.to_owned() }
    }
}

impl FeedFetcher {
    async fn get(&self, etag: Option<&str>) -> Result<FetchOutcome, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = crate::happy_dial::http_client()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(TIMEOUT)
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION"), " (+https://cmux.com)"))
            .build()
            .map_err(|e| e.to_string())?;
        let mut request = client
            .get(&self.url)
            .header("Accept", "application/json")
            .header("Accept-Encoding", "gzip");
        if let Some(etag) = etag {
            request = request.header("If-None-Match", etag);
        }
        let mut response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        if status == 304 {
            return Ok(FetchOutcome::NotModified);
        }
        if status != 200 {
            return Err(format!("the model feed answered {status}"));
        }
        if response.content_length().is_some_and(|n| n > MAX_WIRE_BYTES as u64) {
            return Err(format!("the model feed is above the {MAX_WIRE_BYTES} byte limit"));
        }
        let header = |name: &str| {
            response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
        };
        let etag = header("etag");
        let encoding = header("content-encoding");
        let mut wire = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
            super::fetch::push_capped(&mut wire, &chunk, MAX_WIRE_BYTES)?;
        }
        let body =
            tokio::task::spawn_blocking(move || decode(&wire, encoding.as_deref(), MAX_FEED_BYTES))
                .await
                .map_err(|e| e.to_string())??;
        Ok(FetchOutcome::Body { body, etag })
    }
}

impl Fetcher for FeedFetcher {
    fn fetch<'a>(&'a self, etag: Option<&'a str>) -> BoxFuture<'a, Result<FetchOutcome, String>> {
        Box::pin(self.get(etag))
    }
}
