//! A fork of this home's Chief into a new hosted Cloud Chief, while this
//! home keeps answering (`optchat-chief move --fork --to cloud`, the move
//! tool's `fork` action).
//!
//! A move freezes this home, copies it and marks it moved; a fork does none
//! of that. It copies only what the hosted Chief reads (the memory store,
//! the Chief conversation and the person's profile) from a live snapshot
//! (`VACUUM INTO` takes a consistent copy while the host writes), makes a
//! new hosted Chief that is never the account's default, and records it in
//! `state/fork.json`. The person then talks to the fork through the Mac
//! Chief (`tell("chief:fork", ...)`, see ``ForkPeer``) or `move ask --fork`,
//! and only a real move afterwards replaces anything.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::migrate::{self, Counts, MoveOptions, MoveReport, Target};

/// Where a fork is recorded, on the home it was taken from.
pub const FORK_FILE: &str = "state/fork.json";
/// The fork's peer id in `tell`.
pub const PEER_ID: &str = "chief:fork";
/// The hosted fork's name when the caller gives none.
pub const DEFAULT_NAME: &str = "Chief fork";
/// The longest the cloud's profile field takes (backend brain-store.ts PROFILE_LIMITS).
const INSTRUCTIONS_LIMIT: usize = 32_000;
/// How long a `tell` to the fork waits for its reply.
const REPLY_WAIT: Duration = Duration::from_secs(20 * 60);

/// `state/fork.json`: the hosted Chief a fork made.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fork {
    pub api: String,
    pub chief: String,
    pub conversation: String,
    pub name: String,
    pub at: String,
    /// The home's memory messages when the fork was taken.
    pub memory_messages: u64,
    pub history_imported: usize,
}

/// Reads `state/fork.json` of `home`.
pub fn fork_of(home: &Path) -> Option<Fork> {
    serde_json::from_str(&std::fs::read_to_string(home.join(FORK_FILE)).ok()?).ok()
}

/// The person's profile, as the hosted Chief's `instructions` (trimmed to the
/// cloud's limit on a character boundary).
fn instructions(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join("optchat/person.md")).ok()?;
    if text.trim().is_empty() {
        return None;
    }
    Some(text.chars().take(INSTRUCTIONS_LIMIT).collect())
}

/// Copies the two stores a hosted Chief reads into `tmp` (the checkpoint
/// layout `move_to_cloud` takes) from the live home: seconds, not the full
/// checkpoint's every file.
fn snapshot(home: &Path, tmp: &Path) -> Result<migrate::Manifest, String> {
    let session_dir = migrate::session_dir_for(home);
    let memory_from = home.join("optchat/memory.sqlite3");
    if !memory_from.exists() {
        return Err(format!("{} has no memory store", home.display()));
    }
    let memory_to = tmp.join("files/optchat/memory.sqlite3");
    migrate::create_private_dir(memory_to.parent().unwrap_or(tmp))?;
    migrate::vacuum_into(&memory_from, &memory_to)?;
    let memory = migrate::memory_counts(Some(&migrate::table_counts(&memory_to)?));
    let conv_from = home
        .join("tui")
        .join(&session_dir)
        .join("conversations.sqlite3");
    let mut conversations = Counts::default();
    let has_session = conv_from.exists();
    if has_session {
        let conv_to = tmp
            .join("files/tui")
            .join(&session_dir)
            .join("conversations.sqlite3");
        migrate::create_private_dir(conv_to.parent().unwrap_or(tmp))?;
        migrate::vacuum_into(&conv_from, &conv_to)?;
        conversations.messages = migrate::table_counts(&conv_to)?
            .get("message")
            .copied()
            .unwrap_or(0);
    }
    Ok(migrate::Manifest {
        format: migrate::FORMAT.into(),
        source: migrate::Source {
            host: migrate::hostname(),
            os: std::env::consts::OS.into(),
            arch: std::env::consts::ARCH.into(),
            root: home.to_string_lossy().into_owned(),
        },
        created_at: migrate::now_rfc3339(),
        session_dir: has_session.then_some(session_dir),
        without_transcripts: true,
        memory,
        conversations,
        files: Vec::new(),
        reach: Value::Null,
        backup_id: None,
    })
}

/// Forks the Chief of `options.home` into a new hosted Chief. The home's host
/// keeps running throughout; on an error nothing on the home changed.
pub fn fork(options: &MoveOptions) -> MoveReport {
    let home = std::fs::canonicalize(&options.home).unwrap_or_else(|_| options.home.clone());
    let mut report = MoveReport {
        from: home.to_string_lossy().into_owned(),
        to: options.target.describe(""),
        moved: false,
        forked: false,
        dry_run: options.dry_run,
        steps: Vec::new(),
        memory: Counts::default(),
        conversations: Counts::default(),
        bytes: 0,
        error: None,
        cloud: None,
    };
    let Target::Cloud(t) = &options.target else {
        report.error = Some("a fork goes to the cloud only (--to cloud)".into());
        return report;
    };
    let api = match migrate::timed(&mut report.steps, "preflight", || {
        let base = crate::migrate_cloud::api_base(t)?;
        let token = crate::migrate_cloud::session_token(
            options.session_token_file.as_deref(),
            Some(&base),
        )?;
        let api = crate::migrate_cloud::Api::new(base.clone(), token);
        api.probe_brains()?;
        Ok((
            api,
            format!("{base}: signed in, Cloud Chief brains on; this home keeps answering"),
        ))
    }) {
        Ok(api) => api,
        Err(e) => {
            report.error = Some(e);
            return report;
        }
    };
    if options.dry_run {
        return report;
    }
    let tmp = home
        .parent()
        .unwrap_or(Path::new("/tmp"))
        .join(format!(".chief-fork-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let manifest = match migrate::timed(&mut report.steps, "snapshot", || {
        let m = snapshot(&home, &tmp)?;
        let detail = format!(
            "live copy: {} memory messages, {} conversation messages",
            m.memory.messages, m.conversations.messages
        );
        Ok((m, detail))
    }) {
        Ok(m) => m,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            report.error = Some(e);
            return report;
        }
    };
    report.memory = manifest.memory.clone();
    report.conversations = manifest.conversations.clone();
    // A fresh key per fork: a second fork makes a second Chief, never the first one again.
    let key = format!("{:016x}{}", migrate::now_millis(), std::process::id());
    let name = if options.cloud_name.is_empty() || options.cloud_name == "Chief" {
        DEFAULT_NAME.to_owned()
    } else {
        options.cloud_name.clone()
    };
    let copied = migrate::timed(&mut report.steps, "transfer+verify", || {
        let made = crate::migrate_cloud::move_to_cloud(
            &api,
            &tmp,
            &manifest,
            &key,
            &name,
            false,
            options.cloud_model.as_deref(),
        )?;
        let detail = format!(
            "hosted Chief {} ({} history messages, {} memory messages)",
            made.chief, made.history_imported, made.memory_messages
        );
        Ok((made, detail))
    });
    let _ = std::fs::remove_dir_all(&tmp);
    let made = match copied {
        Ok(m) => m,
        Err(e) => {
            report.error = Some(e);
            return report;
        }
    };
    report.to = format!("cloud:{}/{}", made.api, made.chief);
    report.cloud = Some(made.clone());
    if let Some(text) = instructions(&home)
        && let Err(e) = migrate::timed(&mut report.steps, "profile", || {
            api.put_brain(&made.chief, &json!({"instructions": text}), "profile")
                .map(|()| {
                    (
                        (),
                        "the person's profile (person.md) is the fork's instructions".to_owned(),
                    )
                })
        })
    {
        report.error = Some(e);
        return report;
    }
    let record = Fork {
        api: made.api.clone(),
        chief: made.chief.clone(),
        conversation: made.conversation.clone(),
        name,
        at: migrate::now_rfc3339(),
        memory_messages: manifest.memory.messages,
        history_imported: made.history_imported,
    };
    if let Err(e) = migrate::timed(&mut report.steps, "record", || {
        let text = serde_json::to_string_pretty(&record).map_err(|e| e.to_string())?;
        migrate::write_private(&home.join(FORK_FILE), text.as_bytes())?;
        Ok((
            (),
            format!("{FORK_FILE}; talk to it with tell(id: \"{PEER_ID}\")"),
        ))
    }) {
        report.error = Some(e);
        return report;
    }
    report.forked = true;
    report
}

/// The fork's API with a session (the app's sign-in unless `token_file`).
fn fork_api(fork: &Fork, token_file: Option<&Path>) -> Result<crate::migrate_cloud::Api, String> {
    Ok(crate::migrate_cloud::Api::new(
        fork.api.clone(),
        crate::migrate_cloud::session_token(token_file, Some(&fork.api))?,
    ))
}

/// `move ask --fork`: one message to the fork and its reply.
pub fn ask(home: &Path, text: &str, token_file: Option<&Path>) -> Result<String, String> {
    if text.is_empty() {
        return Err("move ask needs --text".into());
    }
    let fork =
        fork_of(home).ok_or("this home has no fork (optchat-chief move --fork --to cloud)")?;
    let api = fork_api(&fork, token_file)?;
    crate::migrate_cloud::first_turn(
        &api,
        &fork.chief,
        &fork.conversation,
        text,
        Duration::from_secs(600),
    )
}

/// Delivers a fork's reply to the brain as a note; false when the host is gone.
pub type Deliver = Arc<dyn Fn(String) -> bool + Send + Sync>;

/// The fork as a peer of the Mac Chief: `tell("chief:fork", message)` sends
/// the message to the fork's conversation, and its reply comes back as a
/// `[chief:fork] ...` note. The record is read at each call, so a fork made
/// after the host started is reached.
pub struct ForkPeer {
    home: PathBuf,
    deliver: Deliver,
}

impl ForkPeer {
    pub fn new(home: PathBuf, deliver: Deliver) -> ForkPeer {
        ForkPeer { home, deliver }
    }

    /// Whether `id` names the fork (`chief:fork`, or its name after the prefix).
    pub fn names(&self, id: &str) -> bool {
        let id = id.trim();
        if id.eq_ignore_ascii_case(PEER_ID) {
            return true;
        }
        let Some(rest) = id.strip_prefix(crate::peer_chiefs::PREFIX) else {
            return false;
        };
        fork_of(&self.home).is_some_and(|f| f.name.eq_ignore_ascii_case(rest.trim()))
    }

    /// Sends `message` to the fork; its reply is delivered later as a note.
    pub fn tell(&self, message: &str) -> Result<String, String> {
        let fork = fork_of(&self.home)
            .ok_or("tell: there is no fork of this Chief yet (move action fork, to cloud)")?;
        let api = fork_api(&fork, None)?;
        let deliver = self.deliver.clone();
        let text = format!("[from the Mac Chief] {message}");
        let label = fork.name.clone();
        let chief = fork.chief.clone();
        let conversation = fork.conversation.clone();
        // task-owner: one reply wait per tell; ends with the reply or REPLY_WAIT.
        std::thread::spawn(move || {
            let note = match crate::migrate_cloud::first_turn(
                &api,
                &chief,
                &conversation,
                &text,
                REPLY_WAIT,
            ) {
                Ok(reply) => format!("[{PEER_ID}] {reply}"),
                Err(e) => format!("[{PEER_ID}] no reply: {e}"),
            };
            let _ = deliver(note);
        });
        Ok(format!(
            "sent to {label} ({PEER_ID}, hosted Chief {}); its reply comes back as a \"[{PEER_ID}] ...\" note",
            fork.chief
        ))
    }
}
