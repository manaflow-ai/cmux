//! Your own model endpoint as a harness (u2586, docs/chiefs-create-byo-backend.md).
//! Not built yet: the tests come first.

use std::collections::BTreeMap;

/// The profile-env marker of an endpoint harness.
pub const OWN_ENDPOINT_KEY: &str = "ACPMUX_OWN_ENDPOINT";
/// The env key OpenCode's `byo` provider reads its key from.
pub const OPENAI_KEY_ENV: &str = "CMUX_BYO_API_KEY";

/// Which endpoint kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Anthropic,
    OpenAi,
}

impl Kind {
    pub fn of_env(_env: &BTreeMap<String, String>) -> Option<Self> {
        None
    }
}

/// What a failed hello turn says is wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Problem {
    Key,
    BaseUrl,
    Model,
    Other,
}

pub fn classify(_text: &str) -> Problem {
    Problem::Other
}

pub fn fix(_problem: Problem, _kind: Kind, _id: &str) -> String {
    String::new()
}

#[cfg(all(test, unix))]
#[path = "byo_endpoint_tests.rs"]
mod tests;
