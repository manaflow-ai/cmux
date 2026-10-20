//! `btw` in config.json: side sessions (`_acpmux/btw`, `hub/btw.rs`).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `btw` in config.json: `{"model": {"claude": "haiku", "codex": "gpt-5-codex-mini"}}`.
/// `model` is the model a side session starts on, keyed by harness profile or
/// family (the profile wins); a request's own `model` wins over both.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct BtwConfig {
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub model: BTreeMap<String, String>,
}

impl BtwConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}
