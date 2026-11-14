//! Codex over `codex app-server`, presented to the hub as an ACP agent, in
//! process (the cmux-codex-acp library).
//!
//! A profile whose command line is `codex app-server` (kind ACP) is bridged
//! here: acpmux spawns the app-server, and the translator turns the hub's
//! ACP into app-server JSON-RPC and back, in the agent host (durable
//! sessions) or beside a direct child. `codex app-server` never speaks ACP
//! itself, so the command line names the bridge without a new harness kind,
//! and the hub sees a plain ACP agent: sessions, modes, config options,
//! permission requests and native subagent sessions. Nothing outside this
//! file and the library knows the app-server wire format.

use crate::rpc::{Message, RpcError};
use cmux_codex_acp::{Options, Out};
use serde_json::Value;
use std::path::Path;
use std::sync::{Arc, Mutex};

#[cfg(unix)]
use crate::codex_auth_file::{self, AccessFile};
use cmux_json::JsonSet as _;

mod background;
mod message_phases;
pub use background::TERMINATE;
mod usage_limits;
#[cfg(test)]
mod usage_limits_tests;
pub use usage_limits::{is_plan_snapshot, read_usage_limits, usage_limits};

/// The cmux-codex-acp translator, with Codex's background terminals beside
/// it (`background.rs`).
pub struct Translator {
    inner: cmux_codex_acp::Translator,
    background: Mutex<background::Background>,
    message_phases: Mutex<message_phases::MessagePhases>,
    #[cfg(unix)]
    auth: Mutex<AuthGate>,
}

#[cfg(unix)]
struct AuthGate {
    file: Option<AccessFile>,
    pinned_account_id: Option<String>,
    previous_account_id: Option<String>,
    initialize_id: Option<Value>,
    login_id: Option<Value>,
    held: Vec<Out>,
    held_client: Vec<Value>,
    failed: Option<String>,
}

#[cfg(unix)]
impl AuthGate {
    fn new() -> Self {
        Self::from_read(codex_auth_file::read())
    }

    fn from_read(result: anyhow::Result<Option<AccessFile>>) -> Self {
        let file = match result {
            Ok(file) => file,
            Err(error) => {
                return Self {
                    file: None,
                    pinned_account_id: None,
                    previous_account_id: None,
                    initialize_id: None,
                    login_id: None,
                    held: Vec::new(),
                    held_client: Vec::new(),
                    failed: Some(error.to_string()),
                };
            }
        };
        let pinned_account_id = file.as_ref().map(|file| file.account_id.clone());
        Self {
            file,
            pinned_account_id,
            previous_account_id: None,
            initialize_id: None,
            login_id: None,
            held: Vec::new(),
            held_client: Vec::new(),
            failed: None,
        }
    }

    fn enabled(&self) -> bool {
        self.file.is_some() || self.failed.is_some()
    }
    fn pending(&self) -> bool {
        self.login_id.is_some()
    }
    fn should_refresh(&self) -> bool {
        self.file.as_ref().is_some_and(|file| codex_auth_file::changed_since(file.modified))
    }

    fn login_request(&mut self, file: AccessFile) -> Out {
        let id = Value::String(format!("cmux.auth.{}", uuid::Uuid::now_v7()));
        self.login_id = Some(id.clone());
        self.file = Some(file.clone());
        let mut params = serde_json::json!({
            "type": "chatgptAuthTokens",
            "accessToken": file.access_token,
            "chatgptAccountId": file.account_id,
        });
        if let Some(previous) = self.previous_account_id.as_deref() {
            params.set("previousAccountId", Value::String(previous.to_owned()));
        }
        Out::Server(serde_json::json!({
            "jsonrpc": "2.0", "id": id, "method": "account/login/start", "params": params
        }))
    }

    fn account_allowed(&self, file: &AccessFile, requested_previous: Option<&str>) -> bool {
        let expected = self.previous_account_id.as_deref().or(self.pinned_account_id.as_deref());
        expected.is_none_or(|account_id| account_id == file.account_id)
            && requested_previous.is_none_or(|account_id| {
                account_id == file.account_id
                    && expected.is_none_or(|expected| expected == account_id)
            })
    }

    fn failure_reply(msg: &Value, reverse: bool, inner: &cmux_codex_acp::Translator) -> Vec<Out> {
        let Some(id) = msg.get("id") else { return Vec::new() };
        let error = serde_json::json!({"jsonrpc":"2.0", "id":id,
            "error":{"code":-32001,"message":"Codex broker unavailable"}});
        if reverse { inner.from_client(&error) } else { vec![Out::Client(error)] }
    }

    fn fail(&mut self, inner: &cmux_codex_acp::Translator) -> Vec<Out> {
        self.failed = Some("Codex broker unavailable".into());
        self.login_id = None;
        let mut out = Vec::new();
        for held in self.held.drain(..) {
            match held {
                Out::Client(msg) => {
                    out.extend(Self::failure_reply(&msg, msg.get("method").is_some(), inner))
                }
                Out::Server(msg) if msg.get("method").is_none() => {
                    if let Some(id) = msg.get("id") {
                        out.push(Self::refresh_error(id));
                    }
                }
                _ => {}
            }
        }
        for msg in self.held_client.drain(..) {
            out.extend(Self::failure_reply(&msg, msg.get("method").is_none(), inner));
        }
        out
    }

    fn refresh_response(id: &Value, file: &AccessFile) -> Out {
        Out::Server(serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "accessToken": file.access_token,
                "chatgptAccountId": file.account_id
            }
        }))
    }

    fn refresh_error(id: &Value) -> Out {
        Out::Server(serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {"code": -32001, "message": "Codex broker unavailable"}
        }))
    }

    fn handle_refresh<F>(
        &mut self,
        raw: &Value,
        read: F,
        inner: &cmux_codex_acp::Translator,
    ) -> Option<Vec<Out>>
    where
        F: FnOnce() -> anyhow::Result<Option<AccessFile>>,
    {
        if raw.get("method").and_then(Value::as_str) != Some("account/chatgptAuthTokens/refresh") {
            return None;
        }
        let id = raw.get("id")?;
        if let Some(failure) = self.failed.as_ref() {
            tracing::debug!(error = %failure, "Codex broker refresh unavailable");
            return Some(vec![Self::refresh_error(id)]);
        }
        let requested_previous = raw
            .pointer("/params/previousAccountId")
            .or_else(|| raw.pointer("/params/previous_account_id"))
            .and_then(Value::as_str);
        match read() {
            Ok(Some(file))
                if self.account_allowed(&file, requested_previous)
                    && self
                        .file
                        .as_ref()
                        .is_none_or(|old| old.access_token != file.access_token) =>
            {
                self.file = Some(file.clone());
                Some(vec![Self::refresh_response(id, &file)])
            }
            Ok(Some(_)) | Ok(None) | Err(_) => {
                let mut out = vec![Self::refresh_error(id)];
                out.extend(self.fail(inner));
                Some(out)
            }
        }
    }
}

impl Translator {
    fn background(&self) -> std::sync::MutexGuard<'_, background::Background> {
        self.background.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The first lines for the app-server.
    pub fn start(&self) -> Vec<Out> {
        let start = self.inner.start();
        #[cfg(unix)]
        {
            let mut auth = self.auth.lock().unwrap_or_else(|e| e.into_inner());
            auth.initialize_id = start.first().and_then(|out| match out {
                Out::Server(v) => v.get("id").cloned(),
                Out::Client(_) => None,
            });
        }
        start
    }

    /// One message from the hub.
    pub fn from_client(&self, msg: &Value) -> Vec<Out> {
        #[cfg(unix)]
        {
            self.handle_client_read(msg, codex_auth_file::read)
        }
        #[cfg(not(unix))]
        {
            self.handle_client_read(msg)
        }
    }

    fn handle_client_read(
        &self,
        msg: &Value,
        #[cfg(unix)] read: impl FnOnce() -> anyhow::Result<Option<AccessFile>>,
    ) -> Vec<Out> {
        #[cfg(unix)]
        {
            let mut auth = self.auth.lock().unwrap_or_else(|e| e.into_inner());
            // Cancellation controls an existing turn; it must never wait for auth.
            if msg.get("method").and_then(Value::as_str) == Some("session/cancel") {
                return self.inner.from_client(msg);
            }
            if auth.failed.is_some() {
                return AuthGate::failure_reply(msg, msg.get("method").is_none(), &self.inner);
            }
            if auth.enabled() {
                match read() {
                    Ok(Some(file)) if auth.account_allowed(&file, None) => {
                        let changed = auth.file.as_ref().is_none_or(|old| {
                            old.access_token != file.access_token
                                || old.expires_at != file.expires_at
                        });
                        if auth.pending() {
                            auth.held_client.push(msg.clone());
                            return Vec::new();
                        }
                        if changed {
                            auth.held.extend(self.inner.from_client(msg));
                            return vec![auth.login_request(file)];
                        }
                    }
                    _ => {
                        let mut out = auth.fail(&self.inner);
                        out.extend(AuthGate::failure_reply(
                            msg,
                            msg.get("method").is_none(),
                            &self.inner,
                        ));
                        out.extend(self.settle_pending("Codex broker unavailable"));
                        return out;
                    }
                }
            }
        }
        if let Some(out) = self.background().request(msg) {
            return out;
        }
        self.inner.from_client(msg)
    }

    /// One line from the app-server.
    pub fn from_server(&self, raw: &Value) -> Vec<Out> {
        if let Some(out) = self.background().response(raw) {
            return out;
        }
        #[cfg(unix)]
        {
            let mut auth = self.auth.lock().unwrap_or_else(|e| e.into_inner());

            // Codex may ask the app-server's host for a fresh token at any
            // point, including while the initial login gate is settling.  It
            // is a server request, so answer it directly and preserve the
            // opaque JSON-RPC id.  Never pass credentials through the inner
            // translator or hold unrelated output while answering it.
            if auth.enabled()
                && let Some(out) = auth.handle_refresh(raw, codex_auth_file::read, &self.inner)
            {
                if auth.failed.is_some() {
                    let mut out = out;
                    out.extend(self.settle_pending("Codex broker unavailable"));
                    return out;
                }
                return out;
            }

            if let Some(login_id) = auth.login_id.clone() {
                if raw.get("id") == Some(&login_id) {
                    if raw.get("error").is_some() {
                        let mut out = auth.fail(&self.inner);
                        out.extend(self.settle_pending("Codex broker login failed"));
                        return out;
                    }
                    let valid = matches!(
                        codex_auth_file::read(),
                        Ok(Some(file)) if auth.file.as_ref().is_some_and(|old|
                            file.account_id == old.account_id
                                && file.access_token == old.access_token
                                && file.expires_at == old.expires_at)
                    );
                    if !valid {
                        let mut out = auth.fail(&self.inner);
                        out.extend(self.settle_pending("Codex broker unavailable"));
                        return out;
                    }
                    auth.previous_account_id =
                        auth.file.as_ref().map(|file| file.account_id.clone());
                    auth.login_id = None;
                    let mut released = std::mem::take(&mut auth.held);
                    for msg in std::mem::take(&mut auth.held_client) {
                        if let Some(out) = self.background().request(&msg) {
                            released.extend(out);
                        } else {
                            released.extend(self.inner.from_client(&msg));
                        }
                    }
                    return released;
                }
                auth.held.extend(self.background().observe(raw));
                auth.held.extend(self.translate_server(raw));
                return Vec::new();
            }

            if auth.enabled() && auth.initialize_id.as_ref() == raw.get("id") {
                let out = self.translate_server(raw);
                if raw.get("error").is_some() {
                    return out;
                }
                if auth.failed.is_some() {
                    return Vec::new();
                }
                let Some(file) = auth.file.clone() else {
                    return Vec::new();
                };
                let mut visible = Vec::new();
                for item in out {
                    match &item {
                        Out::Server(value)
                            if value.get("method").and_then(Value::as_str)
                                == Some("initialized") =>
                        {
                            visible.push(item)
                        }
                        _ => auth.held.push(item),
                    }
                }
                visible.push(auth.login_request(file));
                return visible;
            }

            if auth.enabled() && !auth.pending() && auth.should_refresh() {
                match codex_auth_file::read() {
                    Ok(Some(file)) if auth.account_allowed(&file, None) => {
                        auth.held.extend(self.background().observe(raw));
                        auth.held.extend(self.translate_server(raw));
                        return vec![auth.login_request(file)];
                    }
                    Ok(None) | Err(_) => {
                        let mut out = auth.fail(&self.inner);
                        out.extend(self.settle_pending("Codex broker unavailable"));
                        return out;
                    }
                    Ok(Some(_)) => {
                        let mut out = auth.fail(&self.inner);
                        out.extend(self.settle_pending("Codex broker unavailable"));
                        return out;
                    }
                }
            }
        }
        let mut out = self.background().observe(raw);
        out.extend(self.translate_server(raw));
        out
    }

    fn translate_server(&self, raw: &Value) -> Vec<Out> {
        let mut out = self.inner.from_server(raw);
        self.message_phases.lock().unwrap_or_else(|e| e.into_inner()).enrich(raw, &mut out);
        out
    }

    /// The app-server exited or its pipe closed.
    pub fn server_closed(&self, why: &str) -> Vec<Out> {
        let mut out = Vec::new();
        #[cfg(unix)]
        out.extend(self.auth.lock().unwrap_or_else(|e| e.into_inner()).fail(&self.inner));
        out.extend(self.settle_pending(why));
        out
    }

    fn settle_pending(&self, why: &str) -> Vec<Out> {
        let mut out = self.inner.server_closed(why);
        out.extend(self.background().closed(why));
        out
    }
}

/// Whether `program args...` runs `codex app-server`: a program named `codex`,
/// `codex-<x>` or `<x>-codex` (a renamed build such as `cmux-codex`; any
/// extension) and whose first argument that is not a global
/// option is `app-server`, with no app-server subcommand after it. Global
/// options before the subcommand (`-c key=value`, `--enable x`, `-p profile`)
/// take one value each.
pub fn is_launch(program: &str, args: &[String]) -> bool {
    let name = Path::new(program).file_stem().and_then(|n| n.to_str()).unwrap_or("");
    if !(name == "codex" || name.starts_with("codex-") || name.ends_with("-codex")) {
        return false;
    }
    let mut i = 0;
    while let Some(a) = args.get(i) {
        if a == "app-server" {
            // `codex app-server <subcommand>` (generate-json-schema, proxy,
            // daemon) is not the server; options after it are.
            return args.get(i + 1).is_none_or(|next| next.starts_with('-'));
        }
        if !a.starts_with('-') {
            return false;
        }
        // `--flag=value` carries its value; `-c value` and `--flag value` do not.
        i += if a.contains('=') { 1 } else { 2 };
    }
    false
}

/// `is_launch` for a profile's argv.
pub fn is_profile_launch(argv: &[String]) -> bool {
    argv.split_first().is_some_and(|(program, args)| is_launch(program, args))
}

/// A translator for one app-server process. It takes one-shot audio prompts
/// (the composer's mic) from any app-server that accepts them: the library
/// advertises `promptCapabilities.audio` only to Codex 0.145.0 or later, so
/// an older `codex` keeps `audio: false` and the pane falls back to dictation.
///
/// Prompt suggestions follow the same global switch as Claude's
/// (`agents.promptSuggestions`, read at each process start): on, each Codex
/// chat has the same `prompt-suggestions` option, and its saved pick comes
/// back with the chat's other options at respawn (`hub/lifecycle.rs`
/// `replay_config`). The library asks Codex's own `thread/prediction/request`
/// first and falls back to a hidden prediction fork while Codex answers it
/// -32601 (cmux-codex-acp `src/translator/suggestions.rs`).
pub fn translator() -> Arc<Translator> {
    translator_with(crate::claude_stdio::prompt_suggestions::enabled_in_settings())
}

fn translator_with(prompt_suggestions: bool) -> Arc<Translator> {
    Arc::new(Translator {
        inner: cmux_codex_acp::Translator::new(Options {
            client_name: "acpmux".into(),
            client_title: "cmux".into(),
            client_version: env!("CARGO_PKG_VERSION").into(),
            audio_input: true,
            prompt_suggestions,
            ..Options::default()
        }),
        background: Mutex::default(),
        message_phases: Mutex::default(),
        #[cfg(unix)]
        auth: Mutex::new(AuthGate::new()),
    })
}

/// What the translator produced: lines for the app-server's stdin and ACP
/// messages for the hub.
#[derive(Default)]
pub struct Split {
    pub server: Vec<Value>,
    pub hub: Vec<Message>,
}

pub fn split(outs: Vec<Out>) -> Split {
    let mut s = Split::default();
    for o in outs {
        match o {
            Out::Server(v) => s.server.push(v),
            Out::Client(v) => match into_message(v) {
                Ok(m) => s.hub.push(m),
                Err(e) => {
                    tracing::warn!("cmux-codex-acp produced a message acpmux cannot parse: {e}")
                }
            },
        }
    }
    s
}

/// `Message::from_value` (it moves the fields; nothing is copied).
fn into_message(v: Value) -> Result<Message, RpcError> {
    Message::from_value(v)
}

/// `Message::into_value`, moving the params instead of copying them.
pub fn into_value(m: Message) -> Value {
    m.into_value()
}

/// The session-log kind of a raw app-server line (`codex.<method>`, or
/// `codex.response`), or None for item notifications and streaming deltas.
pub fn tap_kind(raw: &Value) -> Option<String> {
    match raw.get("method").and_then(Value::as_str) {
        // Item notifications become session updates that carry what they
        // say; logging the raw line too would double the busiest records.
        Some(m) if cmux_codex_acp::is_delta(m) || m.starts_with("item/") => None,
        Some(m) => Some(format!("codex.{m}")),
        None => Some("codex.response".into()),
    }
}

/// Redact credentials before a Codex wire value reaches the session log or
/// viewer. The original value is still sent to Codex; only the tap copy is
/// scrubbed. This covers both JSON field spellings and JWT-shaped strings.
pub fn redact(raw: &Value) -> Value {
    match raw {
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, value)| {
                    let lower = key.to_ascii_lowercase();
                    let secret = matches!(
                        lower.as_str(),
                        "accesstoken"
                            | "refreshtoken"
                            | "idtoken"
                            | "authorization"
                            | "apikey"
                            | "api_key"
                            | "clientsecret"
                            | "client_secret"
                    );
                    (
                        key.clone(),
                        if secret { Value::String("[REDACTED]".into()) } else { redact(value) },
                    )
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(redact).collect()),
        Value::String(value)
            if value.starts_with("eyJ")
                && value.split('.').all(|part| !part.is_empty())
                && value.matches('.').count() == 2 =>
        {
            Value::String("[REDACTED]".into())
        }
        other => other.clone(),
    }
}

/// The session-log kind of a line written to the app-server.
pub const STDIN_KIND: &str = "codex.stdin";

/// One line for the app-server's stdin.
pub fn line(v: &Value) -> String {
    let mut s = v.to_string();
    s.push('\n');
    s
}

#[cfg(test)]
mod tests;
