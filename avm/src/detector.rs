use serde::Serialize;

use crate::policy::{PiiPattern, PolicyAction};

/// A compiled PII/credential detection pattern.
struct CompiledPattern {
    name: String,
    regex: regex::Regex,
    action: PolicyAction,
}

/// A detected PII/credential match.
#[derive(Debug, Clone, Serialize)]
pub struct Detection {
    /// Name of the pattern that matched.
    pub pattern_name: String,
    /// Redacted version of the matched text.
    pub matched_text: String,
    /// Policy action for this match.
    pub action: PolicyAction,
    /// Byte offset in the scanned text.
    pub offset: usize,
}

/// Built-in detection patterns (name, regex, action).
const BUILTIN_PATTERNS: &[(&str, &str, PolicyAction)] = &[
    (
        "email",
        r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}",
        PolicyAction::Warn,
    ),
    (
        "credit_card",
        r"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b",
        PolicyAction::Block,
    ),
    (
        "aws_access_key",
        r"AKIA[0-9A-Z]{16}",
        PolicyAction::Block,
    ),
    (
        "aws_secret_key",
        r"(?i)aws[_\s]*secret[_\s]*access[_\s]*key\s*[=:]\s*[A-Za-z0-9/+=]{40}",
        PolicyAction::Block,
    ),
    (
        "bearer_token",
        r"(?i)bearer\s+[a-zA-Z0-9\-._~+/]{20,}=*",
        PolicyAction::Warn,
    ),
    (
        "github_token",
        r"gh[pousr]_[A-Za-z0-9_]{36,}",
        PolicyAction::Block,
    ),
    (
        "private_key_header",
        r"-----BEGIN\s+(?:RSA\s+|EC\s+|DSA\s+)?PRIVATE\s+KEY-----",
        PolicyAction::Block,
    ),
    (
        "generic_api_key",
        r"(?i)(?:api[_-]?key|apikey)\s*[=:]\s*['\x22]?[A-Za-z0-9\-._~+/]{20,}['\x22]?",
        PolicyAction::Warn,
    ),
];

/// Scans text for PII and credential patterns.
///
/// Merges built-in patterns with user-defined policy patterns.
/// Policy patterns with the same name override built-ins.
pub struct PiiDetector {
    patterns: Vec<CompiledPattern>,
}

impl PiiDetector {
    /// Create a new detector from policy patterns merged with built-ins.
    pub fn new(policy_patterns: &[PiiPattern]) -> Self {
        let mut patterns = Vec::new();
        let mut seen_names: std::collections::HashSet<&str> = std::collections::HashSet::new();

        // Policy patterns take priority.
        for p in policy_patterns {
            match regex::Regex::new(&p.regex) {
                Ok(re) => {
                    seen_names.insert(Box::leak(p.name.clone().into_boxed_str()));
                    patterns.push(CompiledPattern {
                        name: p.name.clone(),
                        regex: re,
                        action: p.action,
                    });
                }
                Err(e) => tracing::warn!(name = %p.name, "invalid PII regex, skipping: {e}"),
            }
        }

        // Add built-ins not overridden by policy.
        for &(name, regex_str, action) in BUILTIN_PATTERNS {
            if !seen_names.contains(name)
                && !policy_patterns.iter().any(|p| p.name == name)
            {
                if let Ok(re) = regex::Regex::new(regex_str) {
                    patterns.push(CompiledPattern {
                        name: name.to_string(),
                        regex: re,
                        action,
                    });
                }
            }
        }

        Self { patterns }
    }

    /// Scan text for PII/credential matches.
    pub fn scan(&self, text: &str) -> Vec<Detection> {
        let mut detections = Vec::new();
        for pattern in &self.patterns {
            for mat in pattern.regex.find_iter(text) {
                detections.push(Detection {
                    pattern_name: pattern.name.clone(),
                    matched_text: redact(mat.as_str()),
                    action: pattern.action,
                    offset: mat.start(),
                });
            }
        }
        detections
    }

    /// Returns the most restrictive action from detections, or `None` if empty.
    pub fn worst_action(detections: &[Detection]) -> Option<PolicyAction> {
        detections
            .iter()
            .map(|d| d.action)
            .max_by_key(|a| match a {
                PolicyAction::Warn => 0,
                PolicyAction::Ask => 1,
                PolicyAction::Block => 2,
            })
    }
}

/// Redact a matched string, showing only first and last 2 characters.
fn redact(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= 4 {
        "*".repeat(chars.len())
    } else {
        let first: String = chars[..2].iter().collect();
        let last: String = chars[chars.len() - 2..].iter().collect();
        let middle_len = chars.len().saturating_sub(4).min(20);
        format!("{first}{}{last}", "*".repeat(middle_len))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detector() -> PiiDetector {
        PiiDetector::new(&[])
    }

    #[test]
    fn detects_email() {
        let d = detector();
        let results = d.scan("send to user@example.com please");
        assert!(results.iter().any(|r| r.pattern_name == "email"));
    }

    #[test]
    fn detects_aws_key() {
        let d = detector();
        let results = d.scan("key is AKIAIOSFODNN7EXAMPLE");
        assert!(results.iter().any(|r| r.pattern_name == "aws_access_key"));
    }

    #[test]
    fn detects_github_token() {
        let d = detector();
        let results = d.scan("token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij");
        assert!(results.iter().any(|r| r.pattern_name == "github_token"));
    }

    #[test]
    fn detects_private_key() {
        let d = detector();
        let results = d.scan("-----BEGIN RSA PRIVATE KEY-----\nMIIE...");
        assert!(
            results
                .iter()
                .any(|r| r.pattern_name == "private_key_header")
        );
    }

    #[test]
    fn detects_credit_card() {
        let d = detector();
        let results = d.scan("card: 4111 1111 1111 1111");
        assert!(results.iter().any(|r| r.pattern_name == "credit_card"));
    }

    #[test]
    fn no_false_positives_on_clean_text() {
        let d = detector();
        let results = d.scan("hello world this is normal text 12345");
        assert!(results.is_empty());
    }

    #[test]
    fn redaction_short() {
        assert_eq!(redact("ab"), "**");
        assert_eq!(redact("abcd"), "****");
    }

    #[test]
    fn redaction_long() {
        assert_eq!(redact("abcdef"), "ab**ef");
        // 20 chars: first 2 + 16 stars + last 2
        assert_eq!(
            redact("AKIAIOSFODNN7EXAMPLE"),
            "AK****************LE"
        );
    }

    #[test]
    fn policy_overrides_builtin() {
        let policy = vec![PiiPattern {
            name: "email".to_string(),
            regex: r"never-match-anything-xxxxx".to_string(),
            action: PolicyAction::Ask,
        }];
        let d = PiiDetector::new(&policy);
        let results = d.scan("user@example.com");
        // The builtin email pattern should NOT match because policy overrode it.
        assert!(results.is_empty());
    }

    #[test]
    fn worst_action_ordering() {
        let detections = vec![
            Detection {
                pattern_name: "a".into(),
                matched_text: "x".into(),
                action: PolicyAction::Warn,
                offset: 0,
            },
            Detection {
                pattern_name: "b".into(),
                matched_text: "y".into(),
                action: PolicyAction::Block,
                offset: 5,
            },
        ];
        assert_eq!(
            PiiDetector::worst_action(&detections),
            Some(PolicyAction::Block)
        );
    }

    #[test]
    fn worst_action_empty() {
        assert_eq!(PiiDetector::worst_action(&[]), None);
    }

    #[test]
    fn detects_bearer_token() {
        let d = detector();
        let results =
            d.scan("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig");
        assert!(results.iter().any(|r| r.pattern_name == "bearer_token"));
    }
}
