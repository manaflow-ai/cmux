//! `acpmux trigger create|ls|rm` (plan M19, "on PR comment or CI failure, wake my Cloud agent"):
//! cmux-platform's Cloud triggers (`src/api/Triggers.ts`, `/v1/triggers`) from a shell. A trigger
//! is a repository filter, a prompt and an existing Cloud machine/workspace/chat: a matching
//! GitHub event (or signed generic webhook) sends the prompt to that chat as one scoped turn, with
//! the platform's dedup, fencing and delivery readback. The platform serves the routes only where
//! its `CLOUD_TRIGGERS` binding is on (development and production today; staging has none), and
//! answers `trigger.not_found` elsewhere.
//!
//! The call is signed with the same cmux sign-in the artifact tools use: config.json's
//! `meshRelay.tokenCommand` (a person's install token; never a joined machine's credential, which
//! the trigger routes refuse). The origin is `--origin`, else the artifact tools' origin
//! (`CMUX_NEXT_ARTIFACTS_API_URL`, `artifacts.baseUrl`, the relay's own origin).
//!
//! The platform has no list route (each trigger is its own Durable Object), so `ls` reads back the
//! ids this home registered (`cloud-triggers.json`: ids and origins only, never a secret) or the
//! ids given. `rm` disables the trigger, which revokes its outstanding principals, then reads it
//! back `enabled: false`.

use anyhow::{Context, Result, anyhow};
use clap::{Args, Subcommand};
use serde_json::{Value, json};
use std::time::Duration;
use zeroize::Zeroizing;

use crate::cli::errors::{AppError, Code};

pub(crate) const RECORD_SCHEMA: &str = "cmux.trigger.record/1";
pub(crate) const LIST_SCHEMA: &str = "cmux.trigger.list/1";
/// The GitHub events the platform matches (`TriggerEvent`).
pub(crate) const GITHUB_EVENTS: [&str; 4] =
    ["ci_failure", "pr_comment", "pr_review_comment", "pr_opened"];
const INDEX_FILE: &str = "cloud-triggers.json";
const MAX_REPLY_BYTES: usize = 1 << 20;

#[derive(Subcommand)]
pub enum TriggerCmd {
    /// Register a trigger: a GitHub event in --repo (or a signed webhook) sends PROMPT to a Cloud
    /// chat. Prints the delivery URL and its signing secret once.
    Create(CreateArgs),
    /// The triggers this home registered (or the ids given), each read back from Cloud.
    #[command(visible_alias = "list")]
    Ls {
        /// Trigger ids to read instead of this home's.
        ids: Vec<String>,
        #[arg(long)]
        origin: Option<String>,
    },
    /// Disable a trigger (its pending runs lose their authority) and read it back disabled.
    #[command(visible_alias = "remove")]
    Rm {
        id: String,
        #[arg(long)]
        origin: Option<String>,
    },
}

#[derive(Args, Clone, Debug, Default)]
pub struct CreateArgs {
    /// OWNER/REPO the events come from.
    #[arg(long)]
    pub repo: String,
    /// An event to start on (repeat): ci_failure, pr_comment, pr_review_comment, pr_opened; with
    /// --webhook, any event name the sender puts in its payload.
    #[arg(long = "on", required = true)]
    pub events: Vec<String>,
    /// A generic signed webhook instead of GitHub.
    #[arg(long)]
    pub webhook: bool,
    /// The GitHub App installation; omit it for a repository webhook pointed at the printed URL.
    #[arg(long, conflicts_with = "webhook")]
    pub installation: Option<u64>,
    /// The Cloud machine whose chat the trigger wakes.
    #[arg(long)]
    pub machine: String,
    #[arg(long)]
    pub workspace: String,
    /// The chat each delivery wakes; with --start-session, the name prefix of the new chat.
    #[arg(long)]
    pub session: String,
    /// The working folder on the machine (absolute).
    #[arg(long)]
    pub cwd: String,
    /// The harness the chat runs (claude, codex, ...).
    #[arg(long, visible_alias = "model")]
    pub harness: String,
    /// Start a new chat per delivery instead of waking --session.
    #[arg(long)]
    pub start_session: bool,
    /// Environment reference recorded with the trigger.
    #[arg(long)]
    pub environment: Option<String>,
    /// Seconds between two runs (0: off). Platform default with --start-session: 600.
    #[arg(long)]
    pub cooldown: Option<u32>,
    /// Runs a day at most (0: off). Platform default with --start-session: 24.
    #[arg(long)]
    pub max_runs_per_day: Option<u32>,
    #[arg(long)]
    pub origin: Option<String>,
    /// What the chat is told on each delivery.
    #[arg(required = true)]
    pub prompt: Vec<String>,
}

/// The `POST /v1/triggers` body (`TriggerCreate`).
pub(crate) fn create_body(args: &CreateArgs) -> Result<Value> {
    let usage = |message: String| anyhow::Error::new(AppError::new(Code::Usage, "usage", message));
    let repo_ok = args.repo.split_once('/').is_some_and(|(owner, name)| {
        let part = |s: &str| {
            !s.is_empty()
                && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        };
        part(owner) && part(name)
    });
    if !repo_ok {
        return Err(usage(format!("--repo {} is not OWNER/REPO", args.repo)));
    }
    if !args.webhook
        && let Some(bad) = args.events.iter().find(|e| !GITHUB_EVENTS.contains(&e.as_str()))
    {
        return Err(usage(format!(
            "--on {bad} is no GitHub trigger event; use {} (or --webhook for any name)",
            GITHUB_EVENTS.join(", ")
        )));
    }
    if !args.cwd.starts_with('/') {
        return Err(usage(format!("--cwd {} must be an absolute path", args.cwd)));
    }
    let prompt = args.prompt.join(" ");
    let mut target = json!({
        "machine": args.machine,
        "workspace": args.workspace,
        "session": args.session,
        "cwd": args.cwd,
        "harness": args.harness,
    });
    if args.start_session {
        target["policy"] = json!("start_session");
    }
    let mut body = json!({
        "repository": args.repo,
        "prompt": prompt,
        "target": target,
        "events": args.events,
    });
    if args.webhook {
        body["source"] = json!("webhook");
    } else if let Some(installation) = args.installation {
        body["installation"] = json!(installation);
    }
    if let Some(environment) = &args.environment {
        body["environment"] = json!(environment);
    }
    if args.cooldown.is_some() || args.max_runs_per_day.is_some() {
        body["guardrails"] = json!({
            "cooldownSeconds": args.cooldown.unwrap_or(600),
            "maxRunsPerDay": args.max_runs_per_day.unwrap_or(24),
        });
    }
    Ok(body)
}

/// A trigger id as the platform takes it (a v4 UUID); checked here so a typo never becomes a path.
pub(crate) fn valid_id(id: &str) -> Result<()> {
    let ok = uuid::Uuid::parse_str(id).is_ok_and(|u| u.get_version_num() == 4) && id.len() == 36;
    if ok {
        Ok(())
    } else {
        Err(anyhow::Error::new(AppError::new(
            Code::Usage,
            "usage",
            format!("{id} is no trigger id"),
        )))
    }
}

/// The trigger routes over HTTPS with one bearer, which it never logs or returns.
pub struct TriggerClient {
    origin: String,
    bearer: Zeroizing<String>,
    http: reqwest::Client,
}

impl TriggerClient {
    pub fn new(origin: String, bearer: Zeroizing<String>) -> Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .default_headers(cmux_build_space::headers()?)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .build()
            .context("build the trigger HTTP client")?;
        Ok(Self { origin, bearer, http })
    }

    pub fn origin(&self) -> &str {
        &self.origin
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<Value> {
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.origin))
            .bearer_auth(self.bearer.as_str());
        if let Some(body) = body {
            request = request.json(body);
        }
        let response =
            request.send().await.map_err(|e| unavailable(format!("{}: {e}", self.origin)))?;
        let status = response.status();
        let bytes = response.bytes().await.map_err(|e| unavailable(e.to_string()))?;
        if bytes.len() > MAX_REPLY_BYTES {
            return Err(unavailable(format!("{} answered more than 1 MiB", self.origin)));
        }
        let value: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        if status.is_success() {
            return Ok(value);
        }
        Err(refusal(status.as_u16(), &value, &self.origin))
    }

    /// `POST /v1/triggers`: the trigger and its secret (returned this once).
    pub async fn create(&self, body: &Value) -> Result<Value> {
        self.call(reqwest::Method::POST, "/v1/triggers", Some(body)).await
    }

    /// `GET /v1/triggers/:id`.
    pub async fn get(&self, id: &str) -> Result<Value> {
        valid_id(id)?;
        self.call(reqwest::Method::GET, &format!("/v1/triggers/{id}"), None).await
    }

    /// `DELETE /v1/triggers/:id`, then a readback that must say `enabled: false`.
    pub async fn remove(&self, id: &str) -> Result<Value> {
        valid_id(id)?;
        let removed =
            self.call(reqwest::Method::DELETE, &format!("/v1/triggers/{id}"), None).await?;
        let read = self.get(id).await?;
        if read.get("enabled").and_then(Value::as_bool) != Some(false) {
            return Err(unavailable(format!("{id} still reads enabled after the remove; retry")));
        }
        Ok(
            json!({"removed": removed.get("removed").cloned().unwrap_or(json!(true)), "trigger": read}),
        )
    }

    /// Where the event source posts: GitHub's webhook or the generic one.
    pub fn delivery_url(&self, trigger: &Value) -> String {
        let id = trigger.get("id").and_then(Value::as_str).unwrap_or_default();
        let kind = if trigger.get("source").and_then(Value::as_str) == Some("webhook") {
            "webhook"
        } else {
            "github"
        };
        format!("{}/v1/triggers/{id}/{kind}", self.origin)
    }
}

fn unavailable(message: String) -> anyhow::Error {
    anyhow::Error::new(
        AppError::new(Code::Runtime, "trigger.unavailable", format!("Cloud triggers: {message}"))
            .retryable(),
    )
}

/// The platform's refusal (`{code, message}`) as one CLI error.
pub(crate) fn refusal(status: u16, body: &Value, origin: &str) -> anyhow::Error {
    let code = body.get("code").and_then(Value::as_str).unwrap_or("trigger.unavailable");
    let said = body.get("message").and_then(Value::as_str).unwrap_or("no message");
    let (kind, message) = match status {
        400 => (Code::Usage, format!("{origin} refused the trigger: {said}")),
        401 => (
            Code::PermissionDenied,
            format!("{origin} took no sign-in ({said}); sign in to cmux on this machine"),
        ),
        403 => (Code::PermissionDenied, format!("{origin} refused: {said}")),
        404 => (
            Code::Runtime,
            format!(
                "{origin}: no such trigger, or Cloud triggers are off there (CLOUD_TRIGGERS is \
                 on in development and production only)"
            ),
        ),
        409 => (Code::Runtime, format!("{origin}: {said}; read it again and retry")),
        _ => (Code::Runtime, format!("{origin} answered {status}: {said}")),
    };
    let mut error = AppError::new(kind, code, message);
    if status == 409 || status >= 500 {
        error = error.retryable();
    }
    anyhow::Error::new(error)
}

/// The origin and the person's install token from config.json (module docs).
async fn client(origin: Option<String>) -> Result<TriggerClient> {
    let text = std::fs::read_to_string(crate::config::Config::path()).unwrap_or_default();
    let (config, relay) = crate::acpmux_mcp::artifacts::settings_from(&text);
    let signed_out = || {
        anyhow::Error::new(AppError::new(
            Code::PermissionDenied,
            "trigger.signed_out",
            "Cloud triggers need this machine's cmux sign-in (config.json meshRelay with a \
             tokenCommand); sign in to cmux, then run this again",
        ))
    };
    let relay = relay
        .filter(|r| {
            r.credential.as_deref() != Some("join")
                && r.token_command.first().is_some_and(|p| !p.trim().is_empty())
        })
        .ok_or_else(signed_out)?;
    let origin = match origin {
        Some(url) => crate::acpmux_mcp::artifacts::platform_origin(&url)?,
        None => {
            let env = std::env::var(crate::acpmux_mcp::artifacts::API_ENV).ok();
            crate::acpmux_mcp::artifacts::base_url(env.as_deref(), &config, Some(&relay))
        }
    };
    let hub = crate::mesh_http::HttpHub::new(&relay).map_err(|e| anyhow!("cmux sign-in: {e}"))?;
    let token = hub.token(false).await.map_err(|_| signed_out())?;
    TriggerClient::new(origin, Zeroizing::new(token.as_str().to_owned()))
}

fn index_path() -> std::path::PathBuf {
    crate::config::home().join(INDEX_FILE)
}

/// This home's registered triggers: `[{origin, id, repository, createdAt}]`.
pub(crate) fn read_index(path: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("triggers").and_then(Value::as_array).cloned())
        .unwrap_or_default()
}

pub(crate) fn write_index(path: &std::path::Path, rows: &[Value]) -> Result<()> {
    crate::config::write_atomic(path, &serde_json::to_vec_pretty(&json!({"triggers": rows}))?)
}

pub(crate) fn indexed_ids(rows: &[Value], origin: &str) -> Vec<String> {
    rows.iter()
        .filter(|r| r.get("origin").and_then(Value::as_str) == Some(origin))
        .filter_map(|r| r.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// One trigger as the CLI prints it.
pub(crate) fn record(trigger: &Value) -> Value {
    let target = trigger.get("target").cloned().unwrap_or(Value::Null);
    json!({
        "schema": RECORD_SCHEMA,
        "id": trigger.get("id"),
        "repository": trigger.get("repository"),
        "source": trigger.get("source").and_then(Value::as_str).unwrap_or("github"),
        "events": trigger.get("events"),
        "enabled": trigger.get("enabled"),
        "revision": trigger.get("revision"),
        "target": target,
        "guardrails": trigger.get("guardrails"),
    })
}

fn line(r: &Value) -> String {
    let s = |v: &Value| v.as_str().unwrap_or("-").to_owned();
    let events: Vec<String> = r["events"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    let state = match r["enabled"].as_bool() {
        Some(true) => "on",
        Some(false) => "off",
        None => r["state"].as_str().unwrap_or("-"),
    };
    format!(
        "{}  {:<4} {}  {}  -> {}/{} ({})",
        s(&r["id"]),
        state,
        s(&r["repository"]),
        events.join(","),
        s(&r["target"]["machine"]),
        s(&r["target"]["session"]),
        s(&r["target"]["harness"]),
    )
}

pub async fn run(cmd: TriggerCmd, json_out: bool) -> Result<()> {
    match cmd {
        TriggerCmd::Create(args) => {
            let body = create_body(&args)?;
            let client = client(args.origin.clone()).await?;
            let created = client.create(&body).await?;
            let trigger = created.get("trigger").cloned().unwrap_or(Value::Null);
            let id = trigger.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
            valid_id(&id).context("the platform answered no trigger id")?;
            let path = index_path();
            let mut rows = read_index(&path);
            rows.push(json!({
                "origin": client.origin(),
                "id": id,
                "repository": trigger.get("repository"),
                "createdAt": crate::store::now_ms(),
            }));
            // The trigger exists either way; a lost index row only hides it from a bare `ls`.
            let indexed = write_index(&path, &rows).is_ok();
            let url = client.delivery_url(&trigger);
            let secret = created.get("secret").and_then(Value::as_str).unwrap_or_default();
            if json_out {
                let mut out = record(&trigger);
                out["deliveryUrl"] = json!(url);
                out["secret"] = json!(secret);
                out["indexed"] = json!(indexed);
                println!("{}", serde_json::to_string_pretty(&out)?);
            } else {
                println!("{}", line(&record(&trigger)));
                println!("Delivery URL: {url}");
                println!("Secret (shown once; set it as the webhook secret): {secret}");
                if !indexed {
                    println!("Not saved to {}; `ls {id}` still reads it.", path.display());
                }
            }
            Ok(())
        }
        TriggerCmd::Ls { ids, origin } => {
            let client = client(origin).await?;
            let ids = if ids.is_empty() {
                indexed_ids(&read_index(&index_path()), client.origin())
            } else {
                ids
            };
            let reads = futures::future::join_all(ids.iter().map(|id| client.get(id))).await;
            let rows: Vec<Value> = ids
                .iter()
                .zip(reads)
                .map(|(id, read)| match read {
                    Ok(trigger) => record(&trigger),
                    Err(e) => json!({"schema": RECORD_SCHEMA, "id": id, "state": "unreadable",
                        "error": crate::cli::errors::classify(&e).message}),
                })
                .collect();
            if json_out {
                let out =
                    json!({"schema": LIST_SCHEMA, "origin": client.origin(), "triggers": rows});
                println!("{}", serde_json::to_string_pretty(&out)?);
            } else if rows.is_empty() {
                println!("No triggers registered from here on {}.", client.origin());
            } else {
                for row in &rows {
                    println!("{}", line(row));
                }
            }
            Ok(())
        }
        TriggerCmd::Rm { id, origin } => {
            let client = client(origin).await?;
            let removed = client.remove(&id).await?;
            let path = index_path();
            let rows = read_index(&path);
            let kept: Vec<Value> = rows
                .iter()
                .filter(|r| {
                    r.get("id").and_then(Value::as_str) != Some(id.as_str())
                        || r.get("origin").and_then(Value::as_str) != Some(client.origin())
                })
                .cloned()
                .collect();
            if kept.len() != rows.len() {
                let _ = write_index(&path, &kept);
            }
            if json_out {
                let mut out = record(&removed["trigger"]);
                out["removed"] = removed["removed"].clone();
                println!("{}", serde_json::to_string_pretty(&out)?);
            } else {
                println!("Disabled {id} (reads enabled: false).");
            }
            Ok(())
        }
    }
}

#[cfg(test)]
#[path = "trigger_tests.rs"]
mod tests;
