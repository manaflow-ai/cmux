//! The owner-side GitHub broker policy.
//!
//! A policy is deliberately expressed as data rather than as a list of
//! command arguments.  The broker accepts only the small action vocabulary in
//! `crate::github_broker`; arbitrary `gh api`, settings, administration and
//! secret operations cannot be smuggled through a grant.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct GithubRepoPolicy {
    /// Action names (`read`, `issue`, `comment`, `draft_pr`, `push`).
    #[serde(default)]
    pub actions: BTreeSet<String>,
    /// Required for `draft_pr` and `push`; an empty list denies those actions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub branch_prefixes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct GithubSessionPolicy {
    /// Repository owner/name -> its grants for this session.
    #[serde(default)]
    pub repos: BTreeMap<String, GithubRepoPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct GithubBrokerConfig {
    /// The broker is fail-closed until an owner turns this on.
    #[serde(default)]
    pub enabled: bool,
    /// Requests from a peer are forwarded to this configured peer. The value
    /// is a local config key, never a peer name supplied by an agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_peer: Option<String>,
    /// Optional owner-only JSON policy file. Inline `sessions` remains useful
    /// for hermetic tests and is merged with the file when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_path: Option<PathBuf>,
    /// Exact acpmux session ids, with `*` as an explicit default grant.
    #[serde(default)]
    pub sessions: BTreeMap<String, GithubSessionPolicy>,
}

impl GithubBrokerConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    pub fn policy_for(&self, session_id: &str) -> Option<&GithubSessionPolicy> {
        self.sessions.get(session_id).or_else(|| self.sessions.get("*"))
    }
}
