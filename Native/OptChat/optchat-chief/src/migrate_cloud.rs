//! `optchat-chief move --to cloud[:staging|:prod|:URL]`: a Chief checkpoint
//! into a Durable-Object-hosted Cloud Chief (ChiefBrainDO), the same calls
//! the app's Hosted Chief copy makes (CmuxNextHostedChief/HostedChiefCopy.swift,
//! HostedChiefCopy+Messages.swift; plans/cmux-next/chief-migration-DESIGN.md 5.1):
//!
//! 1. `chief.create` (idempotent by the checkpoint's hash): a new hosted Chief,
//!    its main conversation and its owner (the account's user id).
//! 2. The brain off while the copy runs (`PUT /v1/chiefs/<id>/brain`).
//! 3. History: the local Chief conversation (`user_local` and `agent_mux`) into
//!    the hosted Chief's empty main conversation (`conversation.import` with
//!    `fill`, batches of 200, then `conversation.import.commit`).
//! 4. Memory: the memory's text export (`main/`, `tree/` JSONL lines) through
//!    `PUT /v1/chiefs/<id>/memory`, batches under 900 KB.
//! 5. The brain on, and a read back of the memory count and state.
//!
//! The account's session token comes from `CMUX_CLOUD_SESSION_TOKEN` or a
//! 0600 file (`--session-token-file`); it is never printed or logged.

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// The local Chief's own id in its owner (cmux_chief::rules::AGENT_MUX).
const LOCAL_CHIEF: &str = "agent_mux";
/// The local person's id in its owner.
const LOCAL_USER: &str = "user_local";
const HISTORY_BATCH: usize = 200;
const HISTORY_BYTES: usize = 700_000;
const MEMORY_BYTES: usize = 900_000;
const MEMORY_LINES: usize = 20_000;

/// Where the account's API is.
pub fn api_base(target: &str) -> Result<String, String> {
    match target {
        "cloud" | "cloud:prod" | "cloud:production" => Ok("https://cloud-api.cmux.dev".into()),
        "cloud:staging" => Ok("https://cloud-api-staging.cmux.dev".into()),
        t => match t.strip_prefix("cloud:") {
            Some(url) if url.starts_with("https://") || url.starts_with("http://127.") => {
                Ok(url.trim_end_matches('/').into())
            }
            _ => Err(format!(
                "unknown cloud target {t}: use cloud, cloud:staging or cloud:https://…"
            )),
        },
    }
}

/// The session token: `CMUX_CLOUD_SESSION_TOKEN`, else the file (must not be
/// readable by others).
pub fn session_token(file: Option<&Path>) -> Result<String, String> {
    if let Some(token) = crate::cli::env("CMUX_CLOUD_SESSION_TOKEN") {
        return Ok(token.trim().to_owned());
    }
    let Some(file) = file else {
        return Err(
            "the cloud target needs the account's session: set CMUX_CLOUD_SESSION_TOKEN \
                    or pass --session-token-file FILE (0600)"
                .into(),
        );
    };
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(file).map_err(|e| format!("{}: {e}", file.display()))?;
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "{} is readable by others: chmod 600 it",
            file.display()
        ));
    }
    let token = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let token = token.trim().to_owned();
    if token.is_empty() {
        return Err(format!("{} is empty", file.display()));
    }
    Ok(token)
}

/// The account's API with one session.
pub struct Api {
    base: String,
    token: String,
    agent: ureq::Agent,
}

impl Api {
    pub fn new(base: String, token: String) -> Api {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(90))
            .build();
        Api { base, token, agent }
    }

    /// One call; the reply's JSON (also for an HTTP error status). The
    /// token never appears in an error.
    fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Result<(u16, Value), String> {
        let request = self
            .agent
            .request(method, &format!("{}{path}", self.base))
            .set("authorization", &format!("Bearer {}", self.token))
            .set("content-type", "application/json")
            .set("user-agent", "optchat-chief-move");
        let result = match body {
            Some(b) => request.send_string(&b.to_string()),
            None => request.call(),
        };
        let response = match result {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => return Err(format!("{method} {path}: {}", transport_text(&e))),
        };
        let status = response.status();
        let text = response.into_string().unwrap_or_default();
        let value = serde_json::from_str(&text).unwrap_or(Value::Null);
        Ok((status, value))
    }

    fn op(&self, name: &str, params: Value, key: &str) -> Result<Value, String> {
        let body = json!({"op": name, "params": params, "origin": "user", "idempotency_key": key});
        let (status, value) = self.call("POST", "/v1/ops", Some(&body))?;
        if value["ok"] == true {
            return Ok(value["value"].clone());
        }
        Err(format!("{name}: HTTP {status} {}", error_text(&value)))
    }

    fn read(&self, name: &str, params: Value) -> Result<Value, String> {
        let (status, value) = self.call(
            "POST",
            "/v1/read",
            Some(&json!({"op": name, "params": params})),
        )?;
        // A read answers `{value}` (no `ok` field); an error has `ok: false`.
        if (200..300).contains(&status) && value["ok"] != false && !value["value"].is_null() {
            return Ok(value["value"].clone());
        }
        Err(format!("{name}: HTTP {status} {}", error_text(&value)))
    }

    /// Signed in, and the service runs Cloud Chief brains (the app's check:
    /// a chief that is not ours answers 403 when brains are on, 404 when off).
    pub fn probe_brains(&self) -> Result<(), String> {
        let (status, _) = self.call(
            "GET",
            "/v1/chiefs/agent_00000000000000000000000000/brain",
            None,
        )?;
        match status {
            401 => Err("the session token is not valid (HTTP 401)".into()),
            404 => Err("this service runs no Cloud Chief brains (404)".into()),
            _ => Ok(()),
        }
    }

    /// Turns a hosted Chief's brain off (a rollback from the cloud).
    pub fn brain_off(&self, chief: &str) -> Result<(), String> {
        self.set_brain(chief, false)
    }

    fn brain(&self, chief: &str) -> Result<Option<bool>, String> {
        let (status, value) = self.call("GET", &format!("/v1/chiefs/{chief}/brain"), None)?;
        if status == 404 {
            return Err("this service runs no Cloud Chief brains (404 on the brain route)".into());
        }
        Ok(value["value"]["config"]["enabled"].as_bool())
    }

    fn set_brain(&self, chief: &str, enabled: bool) -> Result<(), String> {
        let (status, value) = self.call(
            "PUT",
            &format!("/v1/chiefs/{chief}/brain"),
            Some(&json!({"enabled": enabled})),
        )?;
        if (200..300).contains(&status) && value["ok"] != false {
            return Ok(());
        }
        Err(format!(
            "brain {}: HTTP {status} {}",
            if enabled { "on" } else { "off" },
            error_text(&value)
        ))
    }

    /// One `PUT /v1/chiefs/<id>/memory` (the append mode of memory_sync.rs).
    pub fn put_memory(
        &self,
        chief: &str,
        conversation: &str,
        body: &Value,
    ) -> Result<(u16, Value), String> {
        self.call(
            "PUT",
            &format!("/v1/chiefs/{chief}/memory?conversation={conversation}"),
            Some(body),
        )
    }

    fn memory(&self, chief: &str, conversation: &str) -> Result<Value, String> {
        let (status, value) = self.call(
            "GET",
            &format!("/v1/chiefs/{chief}/memory?conversation={conversation}"),
            None,
        )?;
        if value["ok"] == true {
            return Ok(value["value"].clone());
        }
        Err(format!(
            "memory state: HTTP {status} {}",
            error_text(&value)
        ))
    }
}

fn transport_text(e: &ureq::Error) -> String {
    match e {
        ureq::Error::Transport(t) => t.to_string(),
        ureq::Error::Status(code, _) => format!("HTTP {code}"),
    }
}

fn error_text(value: &Value) -> String {
    let e = &value["error"];
    match (e["code"].as_str(), e["message"].as_str()) {
        (Some(c), Some(m)) => format!("{c}: {m}"),
        (Some(c), None) => c.to_owned(),
        _ => value.to_string().chars().take(300).collect(),
    }
}

/// `conv_` + Crockford base32 (26) of sha256("chief-main\0" + chief)
/// (backend user-chief.ts `chiefMainConversation`).
pub fn chief_main_conversation(chief: &str) -> String {
    const CROCKFORD: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let digest = Sha256::digest(format!("chief-main\0{chief}").as_bytes());
    let (mut out, mut buffer, mut bits) = (String::new(), 0u32, 0u32);
    for byte in digest {
        if out.len() >= 26 {
            break;
        }
        buffer = (buffer << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 && out.len() < 26 {
            bits -= 5;
            out.push(char::from(CROCKFORD[((buffer >> bits) & 31) as usize]));
        }
        buffer &= (1 << bits) - 1;
    }
    format!("conv_{out}")
}

/// The local Chief conversation of a checkpoint's conversation store: the
/// conversation of `user_local` and `agent_mux` with the most messages.
pub fn local_history(conversations_db: &Path) -> Result<Vec<Value>, String> {
    if !conversations_db.exists() {
        return Ok(Vec::new());
    }
    let conn = rusqlite::Connection::open_with_flags(
        conversations_db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|e| format!("{}: {e}", conversations_db.display()))?;
    let mut stmt = conn
        .prepare("SELECT id, participants_json, last_seq FROM conversation ORDER BY last_seq DESC")
        .map_err(|e| e.to_string())?;
    let rows: Vec<(String, String, i64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    let chief = rows.into_iter().find(|(_, participants, _)| {
        let p: Value = serde_json::from_str(participants).unwrap_or(Value::Null);
        let ids: Vec<&str> = p
            .as_array()
            .map(|a| a.iter().filter_map(|x| x["id"].as_str()).collect())
            .unwrap_or_default();
        ids.contains(&LOCAL_CHIEF) && ids.contains(&LOCAL_USER) && ids.len() == 2
    });
    let Some((id, _, _)) = chief else {
        return Ok(Vec::new());
    };
    let mut stmt = conn
        .prepare("SELECT message_json FROM message WHERE conversation = ?1 ORDER BY seq")
        .map_err(|e| e.to_string())?;
    let messages = stmt
        .query_map([&id], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .filter_map(|text| serde_json::from_str(&text).ok())
        .collect();
    Ok(messages)
}

fn rewrite_ids(value: &mut Value, user: &str, chief: &str) {
    match value {
        Value::String(s) if s == LOCAL_USER => *s = user.to_owned(),
        Value::String(s) if s == LOCAL_CHIEF => *s = chief.to_owned(),
        Value::Array(a) => a.iter_mut().for_each(|v| rewrite_ids(v, user, chief)),
        Value::Object(m) => {
            for (k, v) in m.iter_mut() {
                if k != "text" {
                    rewrite_ids(v, user, chief);
                }
            }
        }
        _ => {}
    }
}

fn valid_stamp(text: &str) -> Option<String> {
    let parsed = chrono::DateTime::parse_from_rfc3339(text).ok()?;
    Some(
        parsed
            .with_timezone(&chrono::Utc)
            .format("%Y-%m-%dT%H:%M:%S%.3fZ")
            .to_string(),
    )
}

/// The local messages as `conversation.import` messages (the app's
/// `HostedChiefCopy.importMessages`): the person's and the Chief's only,
/// ids mapped, dense seqs, text and work parts (an attachment becomes a short
/// text), times in the owner's form and never going back, references to a
/// dropped message removed. Reactions are not carried.
pub fn import_messages(local: &[Value], user: &str, chief: &str) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut kept: std::collections::HashMap<String, (String, bool)> = Default::default();
    let mut used = std::collections::HashSet::new();
    let mut keys = std::collections::HashSet::new();
    let mut previous: Option<String> = None;
    for message in local {
        let author = message["author"].as_str().unwrap_or("");
        let author = match author {
            LOCAL_USER => user,
            LOCAL_CHIEF => chief,
            _ => continue,
        };
        let local_id = message["id"].as_str().unwrap_or("").to_owned();
        let plain: String = local_id
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .collect();
        let id = if local_id.starts_with("msg_")
            && local_id.len() <= 44
            && local_id[4..].chars().all(|c| c.is_ascii_alphanumeric())
        {
            local_id.clone()
        } else {
            format!("msg_{}", &plain[..plain.len().min(40)])
        };
        if id.len() <= 4 || used.contains(&id) || kept.contains_key(&local_id) {
            continue;
        }
        let created = message["created_at"]
            .as_str()
            .and_then(valid_stamp)
            .or_else(|| previous.clone())
            .unwrap_or_else(|| {
                chrono::Utc::now()
                    .format("%Y-%m-%dT%H:%M:%S%.3fZ")
                    .to_string()
            });
        let created = match &previous {
            Some(p) if *p > created => p.clone(),
            _ => created,
        };
        previous = Some(created.clone());
        let retracted = message["retracted_at"].as_str().and_then(valid_stamp);
        let mut parts: Vec<Value> = Vec::new();
        if retracted.is_none() {
            for part in message["parts"].as_array().cloned().unwrap_or_default() {
                if parts.len() >= 16 {
                    break;
                }
                let keep = match part["type"].as_str() {
                    Some("text") => part["text"].as_str().is_some_and(|t| !t.is_empty()),
                    Some("work") => true,
                    _ => false,
                };
                if keep {
                    let mut part = part;
                    rewrite_ids(&mut part, user, chief);
                    parts.push(part);
                }
            }
            if parts.is_empty() {
                parts.push(json!({"type": "text", "text": "[attachment]"}));
            }
        }
        let mut key = message["client_msg_id"].as_str().unwrap_or("").to_owned();
        if key.is_empty()
            || key.len() > 128
            || key.chars().any(|c| !('\u{21}'..='\u{7e}').contains(&c))
            || keys.contains(&format!("{author}:{key}"))
        {
            key = id.clone();
        }
        keys.insert(format!("{author}:{key}"));
        let mut next = json!({
            "id": id, "seq": out.len() + 1, "client_msg_id": key, "author": author,
            "parts": parts, "created_at": created,
        });
        if let Some(r) = retracted {
            next["retracted_at"] = json!(r.max(created.clone()));
        } else if let Some(e) = message["edited_at"].as_str().and_then(valid_stamp) {
            next["edited_at"] = json!(e.max(created.clone()));
        }
        if let Some((new_id, true)) = message["thread_root"].as_str().and_then(|r| kept.get(r)) {
            next["thread_root"] = json!(new_id);
        }
        let is_root = next.get("thread_root").is_none();
        kept.insert(local_id, (id.clone(), is_root));
        used.insert(id);
        out.push(next);
    }
    out
}

/// The memory's text export lines, sorted as the server takes them.
pub fn memory_lines(memory_db: &Path) -> Result<(Vec<String>, Vec<String>), String> {
    // One folder per call: two exports in one process (parallel tests, or an import's plan and its write) must not share one.
    static EXPORTS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "chief-move-export-{}-{}",
        std::process::id(),
        EXPORTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let db = optchat_host::db::ReadOnly::open(memory_db)
        .map_err(|e| format!("{}: {e}", memory_db.display()))?;
    db.export_text(&dir)
        .map_err(|e| format!("memory export: {e}"))?;
    let read = |sub: &str| -> Result<Vec<String>, String> {
        let mut lines = Vec::new();
        let Ok(entries) = std::fs::read_dir(dir.join(sub)) else {
            return Ok(lines);
        };
        let mut files: Vec<_> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
        files.sort();
        for file in files {
            let text =
                std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
            lines.extend(
                text.lines()
                    .filter(|l| !l.trim().is_empty())
                    .map(str::to_owned),
            );
        }
        Ok(lines)
    };
    let mut main = read("main")?;
    let mut tree = read("tree")?;
    let _ = std::fs::remove_dir_all(&dir);
    let key = |l: &String, a: &str| {
        serde_json::from_str::<Value>(l)
            .ok()
            .and_then(|v| v[a].as_u64())
            .unwrap_or(0)
    };
    main.sort_by_key(|l| key(l, "i"));
    tree.sort_by_key(|l| (key(l, "l"), key(l, "i")));
    Ok((main, tree))
}

/// What a cloud move did.
#[derive(Clone, Debug, serde::Serialize)]
pub struct CloudMoved {
    pub api: String,
    pub chief: String,
    pub conversation: String,
    pub history_imported: usize,
    pub memory_messages: u64,
    pub memory_state: String,
}

/// Copies the checkpoint at `ckpt` into a new hosted Chief.
pub fn move_to_cloud(
    api: &Api,
    ckpt: &Path,
    manifest: &crate::migrate::Manifest,
    checkpoint_sha: &str,
    name: &str,
    make_default: bool,
) -> Result<CloudMoved, String> {
    let short = &checkpoint_sha[..checkpoint_sha.len().min(16)];
    let made = api.op(
        "chief.create",
        json!({"display_name": name, "is_default": make_default}),
        &format!("chief-move-{short}"),
    )?;
    let chief = made["id"]
        .as_str()
        .ok_or("chief.create answered no id")?
        .to_owned();
    let user = made["owner_user"]
        .as_str()
        .ok_or("chief.create answered no owner")?
        .to_owned();
    let conversation = made["main_conversation"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| chief_main_conversation(&chief));
    if api.brain(&chief)? == Some(true) {
        api.set_brain(&chief, false)?;
    }
    // History.
    let conv_db = manifest
        .session_dir
        .as_ref()
        .map(|d| ckpt.join("files/tui").join(d).join("conversations.sqlite3"));
    let local = match &conv_db {
        Some(p) => local_history(p)?,
        None => Vec::new(),
    };
    let messages = import_messages(&local, &user, &chief);
    let mut imported = 0usize;
    if !messages.is_empty() {
        let mut last_seq = 0u64;
        let mut index = 0;
        let mut first = true;
        while index < messages.len() {
            let mut batch = Vec::new();
            let mut bytes = 0;
            while index < messages.len() && batch.len() < HISTORY_BATCH {
                let size = messages[index].to_string().len();
                if !batch.is_empty() && bytes + size > HISTORY_BYTES {
                    break;
                }
                bytes += size;
                batch.push(messages[index].clone());
                index += 1;
            }
            let params = if first {
                json!({"id": conversation, "fill": true,
                       "source": {"kind": "mac", "host": manifest.source.host, "local_id": short},
                       "messages": batch})
            } else {
                json!({"id": conversation, "after_seq": last_seq, "messages": batch})
            };
            let key = format!("chief-move-{short}-history-{index}");
            let value = api.op("conversation.import", params, &key)?;
            last_seq = value["last_seq"]
                .as_u64()
                .unwrap_or(last_seq + batch.len() as u64);
            first = false;
        }
        api.op(
            "conversation.import.commit",
            json!({"id": conversation, "last_seq": last_seq}),
            &format!("chief-move-{short}-commit"),
        )?;
        imported = last_seq as usize;
    }
    // Memory.
    let (main, tree) = memory_lines(&ckpt.join("files/optchat/memory.sqlite3"))?;
    let state = api.memory(&chief, &conversation)?;
    let mut count = state["count"].as_u64().unwrap_or(0) as usize;
    let mut tree_sent = 0usize;
    if state["state"].as_str() != Some("done") {
        loop {
            let mut body_main = Vec::new();
            let mut body_tree = Vec::new();
            let mut bytes = 0;
            while count + body_main.len() < main.len() && body_main.len() < MEMORY_LINES {
                let line = &main[count + body_main.len()];
                if !body_main.is_empty() && bytes + line.len() > MEMORY_BYTES {
                    break;
                }
                bytes += line.len() + 1;
                body_main.push(Value::String(line.clone()));
            }
            while tree_sent + body_tree.len() < tree.len()
                && body_main.len() + body_tree.len() < MEMORY_LINES
            {
                let line = &tree[tree_sent + body_tree.len()];
                if bytes + line.len() > MEMORY_BYTES
                    && !(body_main.is_empty() && body_tree.is_empty())
                {
                    break;
                }
                bytes += line.len() + 1;
                body_tree.push(Value::String(line.clone()));
            }
            let sent_main = body_main.len();
            let sent_tree = body_tree.len();
            let done = count + sent_main >= main.len() && tree_sent + sent_tree >= tree.len();
            let body = json!({"after": count, "main": body_main, "tree": body_tree, "done": done});
            let (status, value) = api.call(
                "PUT",
                &format!("/v1/chiefs/{chief}/memory?conversation={conversation}"),
                Some(&body),
            )?;
            if value["ok"] != true {
                return Err(format!("memory copy: HTTP {status} {}", error_text(&value)));
            }
            count += sent_main;
            tree_sent += sent_tree;
            if done {
                break;
            }
        }
    }
    api.set_brain(&chief, true)?;
    let state = api.memory(&chief, &conversation)?;
    let memory_messages = state["count"].as_u64().unwrap_or(0);
    if memory_messages != main.len() as u64 {
        return Err(format!(
            "the cloud memory holds {memory_messages} messages, the checkpoint {}",
            main.len()
        ));
    }
    Ok(CloudMoved {
        api: api.base.clone(),
        chief,
        conversation,
        history_imported: imported,
        memory_messages,
        memory_state: state["state"].as_str().unwrap_or("").to_owned(),
    })
}

/// Sends one message to the hosted Chief and waits for its reply (a move's
/// first-turn check). Returns the reply text.
pub fn first_turn(
    api: &Api,
    chief: &str,
    conversation: &str,
    text: &str,
    wait: Duration,
) -> Result<String, String> {
    let before = api
        .read(
            "conversation.history",
            json!({"conversation": conversation, "limit": 1}),
        )
        .ok()
        .and_then(|v| {
            v["messages"]
                .as_array()
                .and_then(|m| m.last())
                .and_then(|m| m["seq"].as_u64())
        })
        .unwrap_or(0);
    let key = format!("chief-move-turn-{}", crate::migrate::now_millis());
    api.op(
        "message.send",
        json!({"conversation": conversation, "client_msg_id": key, "parts": [{"type": "text", "text": text}]}),
        &key,
    )?;
    let deadline = std::time::Instant::now() + wait;
    while std::time::Instant::now() < deadline {
        // Bounded wait for the Cloud Chief's reply message; the API has no
        // push for a CLI.
        std::thread::sleep(Duration::from_secs(3));
        let Ok(history) = api.read(
            "conversation.history",
            json!({"conversation": conversation, "limit": 20}),
        ) else {
            continue;
        };
        if let Some(reply) = history["messages"].as_array().and_then(|m| {
            m.iter()
                .find(|x| x["seq"].as_u64().unwrap_or(0) > before + 1 && x["author"] == chief)
        }) {
            let text: Vec<&str> = reply["parts"]
                .as_array()
                .map(|p| p.iter().filter_map(|x| x["text"].as_str()).collect())
                .unwrap_or_default();
            return Ok(text.join("\n"));
        }
    }
    Err("no reply from the Cloud Chief in time".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_conversation_id_has_the_owner_form() {
        let id = chief_main_conversation("agent_01M5CBYPG73VRGQWVFB3TQW8ZD");
        assert!(id.starts_with("conv_") && id.len() == 31, "{id}");
        assert!(
            id[5..]
                .chars()
                .all(|c| "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(c))
        );
    }

    #[test]
    fn import_keeps_the_person_and_the_chief_and_maps_their_ids() {
        let local = vec![
            json!({"id": "msg_A1", "seq": 1, "client_msg_id": "c1", "author": "user_local",
                   "parts": [{"type": "text", "text": "hi agent_mux"}], "created_at": "2026-10-20T09:58:17.931Z"}),
            json!({"id": "msg_B2", "seq": 2, "client_msg_id": "turn:1", "author": "agent_mux",
                   "parts": [{"type": "text", "text": "hello"}, {"type": "image", "url": "x"}],
                   "created_at": "2026-10-20T09:58:10.000Z"}),
            json!({"id": "msg_C3", "seq": 3, "client_msg_id": "c3", "author": "agent_other",
                   "parts": [{"type": "text", "text": "not carried"}], "created_at": "2026-10-20T09:59:00.000Z"}),
            json!({"id": "local-4", "seq": 4, "client_msg_id": "", "author": "user_local",
                   "parts": [{"type": "image", "url": "y"}], "created_at": "bad"}),
        ];
        let out = import_messages(&local, "user_X", "agent_Y");
        assert_eq!(out.len(), 3);
        assert_eq!(out[0]["author"], "user_X");
        assert_eq!(
            out[0]["parts"][0]["text"], "hi agent_mux",
            "text is never rewritten"
        );
        assert_eq!(out[1]["author"], "agent_Y");
        assert_eq!(
            out[1]["parts"].as_array().unwrap().len(),
            1,
            "image part dropped"
        );
        assert_eq!(
            out[1]["created_at"], "2026-10-20T09:58:17.931Z",
            "time never goes back"
        );
        assert_eq!(out[2]["id"], "msg_local4");
        assert_eq!(out[2]["client_msg_id"], "msg_local4");
        assert_eq!(out[2]["parts"][0]["text"], "[attachment]");
        assert_eq!(out[2]["seq"], 3);
    }

    #[test]
    fn cloud_targets() {
        assert_eq!(
            api_base("cloud:staging").unwrap(),
            "https://cloud-api-staging.cmux.dev"
        );
        assert_eq!(api_base("cloud").unwrap(), "https://cloud-api.cmux.dev");
        assert!(api_base("cloud:http://evil.example").is_err());
    }
}
