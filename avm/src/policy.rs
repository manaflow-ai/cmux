use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PolicyError {
    #[error("failed to read policy file at {path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("failed to parse policy file at {path}: {source}")]
    Parse {
        path: PathBuf,
        source: serde_json::Error,
    },
}

/// Action to take when a policy violation is detected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum PolicyAction {
    /// Silently allow (log only).
    Warn,
    /// Pause and prompt the user for approval.
    Ask,
    /// Block the action immediately.
    #[default]
    Block,
}

/// Per-agent resource caps.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceCaps {
    /// Maximum CPU time in seconds (soft limit via `setrlimit`).
    #[serde(default = "default_cpu_time")]
    pub cpu_time_secs: u64,
    /// Maximum resident set size in bytes.
    #[serde(default = "default_rss_bytes")]
    pub rss_bytes: u64,
    /// Maximum virtual address space in bytes (0 = unlimited).
    #[serde(default)]
    pub address_space_bytes: u64,
}

impl Default for ResourceCaps {
    fn default() -> Self {
        Self {
            cpu_time_secs: default_cpu_time(),
            rss_bytes: default_rss_bytes(),
            address_space_bytes: 0,
        }
    }
}

const fn default_cpu_time() -> u64 {
    3600 // 1 hour
}

const fn default_rss_bytes() -> u64 {
    2 * 1024 * 1024 * 1024 // 2 GiB
}

/// Network egress policy.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NetworkPolicy {
    /// Domains that are always allowed.
    #[serde(default)]
    pub allow_domains: Vec<String>,
    /// Domains that are always blocked.
    #[serde(default)]
    pub block_domains: Vec<String>,
    /// Action for domains not in either list.
    #[serde(default)]
    pub default_action: PolicyAction,
}

/// PII / credential detection pattern.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiiPattern {
    pub name: String,
    pub regex: String,
    #[serde(default)]
    pub action: PolicyAction,
}

/// Top-level AVM policy configuration.
///
/// Loaded from `~/.hyperspace/avm-policy.json`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Policy {
    #[serde(default)]
    pub resource_caps: ResourceCaps,
    #[serde(default)]
    pub network: NetworkPolicy,
    #[serde(default)]
    pub pii_patterns: Vec<PiiPattern>,
}

impl Policy {
    /// Default policy file path: `~/.hyperspace/avm-policy.json`.
    pub fn default_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home).join(".hyperspace").join("avm-policy.json")
    }

    /// Load policy from the given path. Returns default policy if the file does not exist.
    pub fn load(path: &Path) -> Result<Self, PolicyError> {
        if !path.exists() {
            tracing::info!(?path, "policy file not found, using defaults");
            return Ok(Self::default());
        }

        let contents =
            std::fs::read_to_string(path).map_err(|source| PolicyError::Read {
                path: path.to_path_buf(),
                source,
            })?;

        serde_json::from_str(&contents).map_err(|source| PolicyError::Parse {
            path: path.to_path_buf(),
            source,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_policy_is_valid() {
        let policy = Policy::default();
        assert_eq!(policy.resource_caps.cpu_time_secs, 3600);
        assert_eq!(policy.resource_caps.rss_bytes, 2 * 1024 * 1024 * 1024);
        assert!(policy.network.allow_domains.is_empty());
        assert!(policy.pii_patterns.is_empty());
    }

    #[test]
    fn parse_full_policy() {
        let json = r#"{
            "resource_caps": {
                "cpu_time_secs": 600,
                "rss_bytes": 1073741824,
                "address_space_bytes": 4294967296
            },
            "network": {
                "allow_domains": ["api.openai.com", "github.com"],
                "block_domains": ["evil.com"],
                "default_action": "ask"
            },
            "pii_patterns": [
                {
                    "name": "email",
                    "regex": "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
                    "action": "warn"
                },
                {
                    "name": "aws_key",
                    "regex": "AKIA[0-9A-Z]{16}",
                    "action": "block"
                }
            ]
        }"#;

        let policy: Policy = serde_json::from_str(json).unwrap();
        assert_eq!(policy.resource_caps.cpu_time_secs, 600);
        assert_eq!(policy.network.allow_domains.len(), 2);
        assert_eq!(policy.network.default_action, PolicyAction::Ask);
        assert_eq!(policy.pii_patterns.len(), 2);
        assert_eq!(policy.pii_patterns[0].name, "email");
        assert_eq!(policy.pii_patterns[1].action, PolicyAction::Block);
    }

    #[test]
    fn parse_minimal_policy() {
        let json = "{}";
        let policy: Policy = serde_json::from_str(json).unwrap();
        assert_eq!(policy.resource_caps.cpu_time_secs, default_cpu_time());
    }

    #[test]
    fn missing_file_returns_default() {
        let path = Path::new("/nonexistent/avm-policy.json");
        let policy = Policy::load(path).unwrap();
        assert_eq!(policy.resource_caps.cpu_time_secs, default_cpu_time());
    }
}
