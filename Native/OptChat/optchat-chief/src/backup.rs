//! The remote backup of the memory's text export (decision 2026-10-06):
//! after each turn's commit, the chat directory's history is pushed to a
//! private per-Chief repository, `manaflow-ai/chief-memory-<chief id>`,
//! created with `gh` on the first push. Never forced: a remote with other
//! history is reported and left alone.
//!
//! Before a push, the export lines added since the last pushed commit are
//! scanned for secrets (gitleaks when it is on PATH, else a built-in set of
//! token and key shapes). A hit holds the backup: nothing is pushed, a
//! `backup_held` trace event is written, and the status file says
//! `(backup held: possible secret in message N)` until the hit is allowed
//! (`backup-allow.txt`: one message id or summary name per line) . A failed
//! push is retried with backoff (30 s doubling to 30 min) by the persister
//! thread; it never blocks a turn.
//!
//! Configuration per Chief home: `OPTCHAT_BACKUP_REMOTE=on|off`, else
//! `optchat/settings.json` `{"backup": {"remote": true|false}}`, else on
//! when `gh auth status` succeeds, except for a tagged dev home
//! (`.../tags/<tag>`), which stays off unless configured: every dogfood tag
//! has its own home and would otherwise make its own repository.
//! `OPTCHAT_BACKUP_URL` pushes to another remote instead (a local bare
//! repository in tests).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::paths::Paths;

/// The GitHub organization the backups live in.
pub const ORG: &str = "manaflow-ai";
/// The git remote name in the chat repository.
const REMOTE: &str = "backup";
/// The remote-tracking ref of the last pushed commit.
const PUSHED: &str = "refs/remotes/backup/main";
/// Git's empty tree: the base of the first scan.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
const FIRST_RETRY: Duration = Duration::from_secs(30);
const LAST_RETRY: Duration = Duration::from_secs(30 * 60);

/// Where a backup goes and where it reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackupConfig {
    /// On, off, or None: on when `gh auth status` succeeds (checked once).
    pub remote: Option<bool>,
    /// A tagged dev home: None above means off.
    pub tagged: bool,
    /// The push URL; None: the per-Chief GitHub repository.
    pub url: Option<String>,
    /// `manaflow-ai/chief-memory-<chief id>`.
    pub repo: String,
    /// `optchat/backup.json`: the last outcome, for the debug view and stats.
    pub status: PathBuf,
    /// `optchat/traces/`: `backup_*` events in the trace format.
    pub traces: PathBuf,
    /// `optchat/backup-allow.txt`: hits the user allowed.
    pub allow: PathBuf,
}

fn on_off(text: &str) -> Option<bool> {
    match text.trim().to_ascii_lowercase().as_str() {
        "on" | "1" | "true" | "yes" => Some(true),
        "off" | "0" | "false" | "no" => Some(false),
        _ => None,
    }
}

impl BackupConfig {
    /// The configuration of the Chief home `paths` with id `chief_id`.
    pub fn for_home(paths: &Paths, chief_id: &str) -> BackupConfig {
        let settings = std::fs::read(paths.root.join("settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v.pointer("/backup/remote").and_then(Value::as_bool));
        let remote = crate::cli::env("OPTCHAT_BACKUP_REMOTE")
            .and_then(|v| on_off(&v))
            .or(settings);
        let tagged = paths
            .home
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == "tags");
        BackupConfig {
            remote,
            tagged,
            url: crate::cli::env("OPTCHAT_BACKUP_URL"),
            repo: format!("{ORG}/chief-memory-{chief_id}"),
            status: paths.root.join("backup.json"),
            traces: paths.root.join("traces"),
            allow: paths.root.join("backup-allow.txt"),
        }
    }
}

/// What one backup attempt did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Remote backup is off for this home.
    Off,
    /// Nothing new since the last push.
    UpToDate,
    Pushed {
        head: String,
    },
    /// A possible secret in `what` ("message 12", "summary 8+4"): not pushed.
    Held {
        what: String,
        rule: String,
    },
    /// The push failed; retried after `retry`.
    Failed {
        error: String,
        retry: Duration,
    },
}

pub struct Backup {
    config: BackupConfig,
    remote: Option<bool>,
    created: bool,
    delay: Duration,
    due: Option<Instant>,
}

/// One secret shape: a prefix, the characters that follow it and how many.
struct Shape {
    rule: &'static str,
    prefix: &'static str,
    chars: fn(u8) -> bool,
    min: usize,
}

fn token(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

fn alnum(b: u8) -> bool {
    b.is_ascii_alphanumeric()
}

fn upper_digit(b: u8) -> bool {
    b.is_ascii_uppercase() || b.is_ascii_digit()
}

fn url_part(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'/' || b == b'_' || b == b'-'
}

const SHAPES: &[Shape] = &[
    Shape {
        rule: "github-token",
        prefix: "ghp_",
        chars: alnum,
        min: 36,
    },
    Shape {
        rule: "github-token",
        prefix: "gho_",
        chars: alnum,
        min: 36,
    },
    Shape {
        rule: "github-token",
        prefix: "ghu_",
        chars: alnum,
        min: 36,
    },
    Shape {
        rule: "github-token",
        prefix: "ghs_",
        chars: alnum,
        min: 36,
    },
    Shape {
        rule: "github-token",
        prefix: "ghr_",
        chars: alnum,
        min: 36,
    },
    Shape {
        rule: "github-pat",
        prefix: "github_pat_",
        chars: token,
        min: 60,
    },
    Shape {
        rule: "anthropic-key",
        prefix: "sk-ant-",
        chars: token,
        min: 32,
    },
    Shape {
        rule: "openai-key",
        prefix: "sk-proj-",
        chars: token,
        min: 32,
    },
    Shape {
        rule: "openai-key",
        prefix: "sk-svcacct-",
        chars: token,
        min: 32,
    },
    Shape {
        rule: "aws-access-key",
        prefix: "AKIA",
        chars: upper_digit,
        min: 16,
    },
    Shape {
        rule: "aws-access-key",
        prefix: "ASIA",
        chars: upper_digit,
        min: 16,
    },
    Shape {
        rule: "slack-token",
        prefix: "xoxb-",
        chars: token,
        min: 20,
    },
    Shape {
        rule: "slack-token",
        prefix: "xoxp-",
        chars: token,
        min: 20,
    },
    Shape {
        rule: "slack-token",
        prefix: "xoxa-",
        chars: token,
        min: 20,
    },
    Shape {
        rule: "slack-webhook",
        prefix: "hooks.slack.com/services/T",
        chars: url_part,
        min: 20,
    },
    Shape {
        rule: "stripe-key",
        prefix: "sk_live_",
        chars: alnum,
        min: 20,
    },
    Shape {
        rule: "stripe-key",
        prefix: "rk_live_",
        chars: alnum,
        min: 20,
    },
    Shape {
        rule: "google-api-key",
        prefix: "AIza",
        chars: token,
        min: 35,
    },
    Shape {
        rule: "npm-token",
        prefix: "npm_",
        chars: alnum,
        min: 36,
    },
];

/// The first secret shape in `text`, if any (the built-in scan).
pub fn find_secret(text: &str) -> Option<&'static str> {
    let bytes = text.as_bytes();
    if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") {
        return Some("private-key");
    }
    for shape in SHAPES {
        let mut from = 0;
        while let Some(k) = text[from..].find(shape.prefix) {
            let start = from + k;
            let before = start.checked_sub(1).map(|p| bytes[p]);
            let after = start + shape.prefix.len();
            let run = bytes[after..]
                .iter()
                .take_while(|b| (shape.chars)(**b))
                .count();
            if before.is_none_or(|b| !b.is_ascii_alphanumeric()) && run >= shape.min {
                return Some(shape.rule);
            }
            from = after;
        }
    }
    None
}

/// Which message or summary an added export line is.
fn line_owner(line: &str) -> String {
    match serde_json::from_str::<Value>(line) {
        Ok(v) => match (
            v.get("l").and_then(Value::as_u64),
            v.get("i").and_then(Value::as_u64),
        ) {
            (Some(l), Some(i)) => {
                format!("summary {}", optchat_host::NodeId::new(l as u32, i).name())
            }
            (None, Some(i)) => format!("message {i}"),
            _ => "an export line".to_owned(),
        },
        Err(_) => "an export line".to_owned(),
    }
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| format!("running git: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    } else {
        Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .map_err(|e| format!("running gh: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    } else {
        Err(format!(
            "gh {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

impl Backup {
    pub fn new(config: BackupConfig) -> Backup {
        Backup {
            remote: config.remote,
            config,
            created: false,
            delay: FIRST_RETRY,
            due: None,
        }
    }

    /// When a failed push should be tried again.
    pub fn due(&self) -> Option<Instant> {
        self.due
    }

    fn url(&self) -> String {
        self.config
            .url
            .clone()
            .unwrap_or_else(|| format!("https://github.com/{}.git", self.config.repo))
    }

    fn allowed(&self) -> Vec<String> {
        std::fs::read_to_string(&self.config.allow)
            .unwrap_or_default()
            .lines()
            .map(|l| l.trim().to_owned())
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect()
    }

    /// A possible secret in the export lines added in `base..HEAD`.
    fn scan(&self, dir: &Path, base: &str) -> Result<Option<(String, String)>, String> {
        let allowed = self.allowed();
        let is_allowed = |what: &str| {
            let id = what.rsplit(' ').next().unwrap_or("");
            allowed.iter().any(|a| a == id || a == what)
        };
        if let Some(hit) = gitleaks(dir, base)?
            && !is_allowed(&hit.0)
        {
            return Ok(Some(hit));
        }
        let diff = git(
            dir,
            &[
                "diff",
                "--unified=0",
                "--no-color",
                base,
                "HEAD",
                "--",
                "main",
                "tree",
            ],
        )?;
        for line in diff.lines() {
            let Some(added) = line.strip_prefix('+').filter(|_| !line.starts_with("+++")) else {
                continue;
            };
            if let Some(rule) = find_secret(added) {
                let what = line_owner(added);
                if !is_allowed(&what) {
                    return Ok(Some((what, rule.to_owned())));
                }
            }
        }
        Ok(None)
    }

    /// One attempt: scan what is new since the last push, then push it.
    pub fn run(&mut self, dir: &Path) -> Outcome {
        let outcome = self.attempt(dir);
        match &outcome {
            Outcome::Failed { .. } => {}
            _ => {
                self.delay = FIRST_RETRY;
                self.due = None;
            }
        }
        self.report(&outcome);
        outcome
    }

    fn attempt(&mut self, dir: &Path) -> Outcome {
        let (url, tagged) = (self.config.url.is_some(), self.config.tagged);
        let remote = *self
            .remote
            .get_or_insert_with(|| url || (!tagged && gh(&["auth", "status"]).is_ok()));
        if !remote {
            return Outcome::Off;
        }
        let Ok(head) = git(dir, &["rev-parse", "--verify", "-q", "HEAD"]) else {
            return Outcome::UpToDate;
        };
        let pushed = git(dir, &["rev-parse", "--verify", "-q", PUSHED]).ok();
        if pushed.as_deref() == Some(head.as_str()) {
            return Outcome::UpToDate;
        }
        let base = pushed.clone().unwrap_or_else(|| EMPTY_TREE.to_owned());
        match self.scan(dir, &base) {
            Ok(Some((what, rule))) => return Outcome::Held { what, rule },
            Ok(None) => {}
            Err(error) => return self.failed(error),
        }
        if let Err(error) = self.push(dir, &head) {
            return self.failed(error);
        }
        Outcome::Pushed { head }
    }

    fn push(&mut self, dir: &Path, head: &str) -> Result<(), String> {
        let url = self.url();
        match git(dir, &["remote", "get-url", REMOTE]) {
            Ok(current) if current == url => {}
            Ok(_) => git(dir, &["remote", "set-url", REMOTE, &url]).map(|_| ())?,
            Err(_) => git(dir, &["remote", "add", REMOTE, &url]).map(|_| ())?,
        }
        if self.config.url.is_none() && !self.created {
            if gh(&["repo", "view", &self.config.repo, "--json", "name"]).is_err() {
                gh(&[
                    "repo",
                    "create",
                    &self.config.repo,
                    "--private",
                    "--disable-issues",
                    "--disable-wiki",
                    "--description",
                    "OptChat Chief memory: the text export, pushed after every turn",
                ])?;
            }
            self.created = true;
        }
        // gh signs the push in for github.com; never forced.
        let helper = "credential.helper=!gh auth git-credential";
        let mut args: Vec<&str> = Vec::new();
        if self.config.url.is_none() {
            args.extend(["-c", "credential.helper=", "-c", helper]);
        }
        let refspec = format!("{head}:refs/heads/main");
        args.extend(["push", "--quiet", REMOTE, &refspec]);
        git(dir, &args)?;
        git(dir, &["update-ref", PUSHED, head]).map(|_| ())
    }

    fn failed(&mut self, error: String) -> Outcome {
        let retry = self.delay;
        self.due = Some(Instant::now() + retry);
        self.delay = (self.delay * 2).min(LAST_RETRY);
        Outcome::Failed { error, retry }
    }

    /// The status file and the trace event of an outcome.
    fn report(&self, outcome: &Outcome) {
        let at = chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false);
        let (status, event) = match outcome {
            Outcome::Off => (json!({"state": "off", "at": at}), None),
            Outcome::UpToDate => return,
            Outcome::Pushed { head } => (
                json!({"state": "ok", "head": head, "repo": self.config.repo, "at": at}),
                Some(("backup_pushed", json!({"head": head}))),
            ),
            Outcome::Held { what, rule } => {
                let text = format!("(backup held: possible secret in {what})");
                (
                    json!({"state": "held", "text": text, "what": what, "rule": rule, "at": at}),
                    Some(("backup_held", json!({"what": what, "rule": rule}))),
                )
            }
            Outcome::Failed { error, retry } => (
                json!({"state": "retrying", "error": error, "retry_s": retry.as_secs(), "at": at}),
                Some((
                    "backup_failed",
                    json!({"error": error, "retry_s": retry.as_secs()}),
                )),
            ),
        };
        let tmp = self.config.status.with_extension("json.tmp");
        if std::fs::write(&tmp, status.to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, &self.config.status);
        }
        if let Some((ev, fields)) = event {
            trace_event(&self.config.traces, ev, fields);
        }
    }
}

/// gitleaks over `base..HEAD`, when it is on PATH: the first finding's
/// owner and rule, None when clean or when gitleaks is missing or fails
/// (the built-in scan runs anyway).
fn gitleaks(dir: &Path, base: &str) -> Result<Option<(String, String)>, String> {
    let report = std::env::temp_dir().join(format!("optchat-gitleaks-{}.json", std::process::id()));
    let range = if base == EMPTY_TREE {
        "HEAD".to_owned()
    } else {
        format!("{base}..HEAD")
    };
    let out = Command::new("gitleaks")
        .args([
            "detect",
            "--no-banner",
            "--redact",
            "--exit-code",
            "3",
            "--report-format",
            "json",
        ])
        .arg("--report-path")
        .arg(&report)
        .arg("--source")
        .arg(dir)
        .arg(format!("--log-opts={range}"))
        .output();
    let Ok(out) = out else {
        return Ok(None);
    };
    if out.status.code() != Some(3) {
        let _ = std::fs::remove_file(&report);
        return Ok(None);
    }
    let findings: Value = std::fs::read(&report)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    let _ = std::fs::remove_file(&report);
    let Some(first) = findings.as_array().and_then(|a| a.first()) else {
        return Ok(Some(("an export line".into(), "gitleaks".into())));
    };
    let rule = first["RuleID"].as_str().unwrap_or("gitleaks").to_owned();
    let what = match (first["File"].as_str(), first["StartLine"].as_u64()) {
        (Some(file), Some(n)) => git(dir, &["show", &format!("HEAD:{file}")])
            .ok()
            .and_then(|text| {
                text.lines()
                    .nth(n.saturating_sub(1) as usize)
                    .map(line_owner)
            })
            .unwrap_or_else(|| "an export line".to_owned()),
        _ => "an export line".to_owned(),
    };
    Ok(Some((what, rule)))
}

/// One trace line, `{"ts", "ev", ...}`, in `dir/YYYY-MM-DD.jsonl` (the
/// trace format, mode 0600); a failed write is dropped.
pub fn trace_event(dir: &Path, ev: &str, fields: Value) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if optchat_host::db::private_dir(dir).is_err() {
        return;
    }
    let now = chrono::Local::now();
    let mut line = json!({"ts": now.timestamp_millis(), "ev": ev});
    if let (Some(map), Value::Object(extra)) = (line.as_object_mut(), fields) {
        map.extend(extra);
    }
    let mut bytes = line.to_string().into_bytes();
    bytes.push(b'\n');
    let file = dir.join(format!("{}.jsonl", now.format("%Y-%m-%d")));
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(file)
    {
        let _ = f.write_all(&bytes);
    }
}
