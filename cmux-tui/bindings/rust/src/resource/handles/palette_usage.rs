//! The user's palette usage history on a session handle: `palette_usage.get`,
//! `.record`, `.hide`, `.forget` and `.import` (resource-api-v2.md;
//! capability `palette-usage-v1`, plans/cmux-next/palette-ranking.md 5.2-5.3).
//!
//! The daemon is the history's one writer and stamps each use with its own
//! clock. Scores are stored as of `last_used_ms`; readers decay them to their
//! own clock with the half-lives the snapshot names. The ranking rules that
//! read the history live in the shared palette ranker, not here.
//!
//! The snapshots decode forward-compatibly: fields this SDK does not know
//! stay in `additional`.

use super::super::*;
use crate::resource::model::deserialize_decimal;
use serde::Deserialize;
use std::collections::BTreeMap;

/// The daemon capability of the palette usage history.
pub const PALETTE_USAGE_CAPABILITY: &str = "palette-usage-v1";
/// Longest usage key (`action:<id>`, `setting:<id>`, `tab:<id>`, ...).
pub const PALETTE_USAGE_KEY_MAX_CHARS: usize = 512;
/// Longest query a use may record a learned pick for.
const QUERY_MAX_CHARS: usize = 1024;
/// Longest import source name.
const SOURCE_MAX_CHARS: usize = 256;
/// Most rows one import may carry.
pub const PALETTE_USAGE_IMPORT_MAX_ROWS: usize = 500;

/// One used row (`PaletteUsageRow`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct PaletteUsageRow {
    pub key: String,
    /// The decayed use count as of `last_used_ms`.
    pub score: f64,
    /// The daemon's clock (Unix milliseconds) at the latest use.
    #[serde(deserialize_with = "deserialize_decimal")]
    pub last_used_ms: u64,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One learned pick (`PaletteUsagePick`): the row run for a query start.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct PaletteUsagePick {
    /// A normalized query start (lowercased, white space collapsed, 1 to 8
    /// characters).
    pub prefix: String,
    pub key: String,
    /// The decayed pick count as of `last_used_ms`.
    pub score: f64,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub last_used_ms: u64,
    /// This row is the latest pick for `prefix`.
    pub last: bool,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// The whole history (`PaletteUsageSnapshot`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct PaletteUsageSnapshot {
    /// Increases by one per committed change; 0 before the first use.
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub half_life_ms: u64,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub pick_half_life_ms: u64,
    /// Used rows, most used first.
    pub entries: Vec<PaletteUsageRow>,
    /// Learned picks by prefix, strongest first within a prefix.
    pub picks: Vec<PaletteUsagePick>,
    /// Sources already imported.
    pub imported: Vec<String>,
    /// Keys of the rows the user hid.
    pub hidden: Vec<String>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// The history revision after a record, hide or forget
/// (`PaletteUsageRecordResult`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct PaletteUsageRevision {
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// What `palette_usage.import` did (`PaletteUsageImportResult`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct PaletteUsageImportResult {
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    /// False when the source was imported before and nothing changed.
    pub imported: bool,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One former row for `palette_usage.import`.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteUsageImportRow {
    pub key: String,
    /// The decayed use count as of `last_used_ms`.
    pub score: f64,
    /// Unix milliseconds of the latest use.
    pub last_used_ms: u64,
}

impl Session {
    /// The whole palette usage history.
    pub fn palette_usage(&self) -> Result<PaletteUsageSnapshot> {
        let value = self.client.read(ops::PALETTE_USAGE_GET, self.params())?;
        wire::decode_exact(&value, "palette usage")
    }

    /// One run of row `key`, for `query` (empty records no learned pick),
    /// with a fresh idempotency key.
    pub fn record_palette_use(
        &self,
        key: &str,
        query: &str,
    ) -> Result<MutationResult<PaletteUsageRevision>> {
        self.record_palette_use_with(key, query, MutationOptions::unique()?)
    }

    pub fn record_palette_use_with(
        &self,
        key: &str,
        query: &str,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaletteUsageRevision>> {
        validate_key(key)?;
        if query.chars().count() > QUERY_MAX_CHARS {
            return Err(Error::InvalidArgument(format!(
                "palette usage query must be at most {QUERY_MAX_CHARS} characters"
            )));
        }
        let mut params = self.params().string("key", key);
        if !query.is_empty() {
            params = params.string("query", query);
        }
        mutation_snapshot(
            self.client.mutate(ops::PALETTE_USAGE_RECORD, params, mutation)?,
            "palette usage revision",
        )
    }

    /// Hides row `key` from the palette (`hidden` true), or shows it again.
    pub fn hide_palette_row(
        &self,
        key: &str,
        hidden: bool,
    ) -> Result<MutationResult<PaletteUsageRevision>> {
        self.hide_palette_row_with(key, hidden, MutationOptions::unique()?)
    }

    pub fn hide_palette_row_with(
        &self,
        key: &str,
        hidden: bool,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaletteUsageRevision>> {
        validate_key(key)?;
        mutation_snapshot(
            self.client.mutate(
                ops::PALETTE_USAGE_HIDE,
                self.params().string("key", key).boolean("hidden", hidden),
                mutation,
            )?,
            "palette usage revision",
        )
    }

    /// Reset Ranking: forgets every use and learned pick of row `key`.
    pub fn forget_palette_row(&self, key: &str) -> Result<MutationResult<PaletteUsageRevision>> {
        self.forget_palette_row_with(key, MutationOptions::unique()?)
    }

    pub fn forget_palette_row_with(
        &self,
        key: &str,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaletteUsageRevision>> {
        validate_key(key)?;
        mutation_snapshot(
            self.client.mutate(
                ops::PALETTE_USAGE_FORGET,
                self.params().string("key", key),
                mutation,
            )?,
            "palette usage revision",
        )
    }

    /// Merges a former history from `source` once (a source imported
    /// before changes nothing).
    pub fn import_palette_usage(
        &self,
        source: &str,
        rows: &[PaletteUsageImportRow],
    ) -> Result<MutationResult<PaletteUsageImportResult>> {
        self.import_palette_usage_with(source, rows, MutationOptions::unique()?)
    }

    pub fn import_palette_usage_with(
        &self,
        source: &str,
        rows: &[PaletteUsageImportRow],
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaletteUsageImportResult>> {
        if source.is_empty() || source.chars().count() > SOURCE_MAX_CHARS {
            return Err(Error::InvalidArgument(format!(
                "palette usage import source must be 1 to {SOURCE_MAX_CHARS} characters"
            )));
        }
        if rows.len() > PALETTE_USAGE_IMPORT_MAX_ROWS {
            return Err(Error::InvalidArgument(format!(
                "palette usage import takes at most {PALETTE_USAGE_IMPORT_MAX_ROWS} rows"
            )));
        }
        let mut entries = Vec::with_capacity(rows.len());
        for row in rows {
            validate_key(&row.key)?;
            if !row.score.is_finite() {
                return Err(Error::InvalidArgument(
                    "palette usage import score must be finite".to_string(),
                ));
            }
            entries.push(serde_json::json!({
                "key": row.key,
                "score": row.score,
                // A decimal string (catalog `decimal`).
                "last_used_ms": row.last_used_ms.to_string(),
            }));
        }
        mutation_snapshot(
            self.client.mutate(
                ops::PALETTE_USAGE_IMPORT,
                self.params().string("source", source).value("entries", Value::Array(entries)),
                mutation,
            )?,
            "palette usage import result",
        )
    }
}

fn validate_key(key: &str) -> Result<()> {
    if key.trim().is_empty() || key.chars().count() > PALETTE_USAGE_KEY_MAX_CHARS {
        return Err(Error::InvalidArgument(format!(
            "palette usage key must be 1 to {PALETTE_USAGE_KEY_MAX_CHARS} characters"
        )));
    }
    Ok(())
}
