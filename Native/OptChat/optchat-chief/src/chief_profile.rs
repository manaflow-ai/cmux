//! This Chief's own record in the daemon's Chief registry (multi-Chief S5,
//! bead cx-ebm.60.5; hq .cmux-scratch/hq6d-multi-chief/DESIGN.md sections 4
//! and 6): its profile in the system prompt, the tools the person granted,
//! and the `profile` tool with which it changes its own fields.
//!
//! The record is read once at host start on the Chief's own bound
//! connection (`chief.profile.get`), so the prompt and the tool list stay
//! byte-identical for the host's life (the prompt cache holds). A change of
//! the text fields shows in the prompt from the brain's next start.
//!
//! The grant is enforced in code: an ungranted model tool is not in the MCP
//! tool list, and the tools socket refuses it by name (the `chief` launcher
//! of a non-Claude harness asks the socket directly). `spawn` with a
//! subagent harness outside `harnesses` is refused by the spawner.
//!
//! `profile` changes go over the same bound connection, so the daemon
//! checks the Chief's identity and the person's `self_edit` rule; this file
//! only phrases the answers.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine as _;
use cmux::raw::{Client, ClientConfig, ConversationBindRequest, Error as SdkError};
use serde_json::{Map, Value, json};

/// The default Chief's participant id.
pub const DEFAULT_CHIEF: &str = cmux_chief::rules::AGENT_MUX;

/// The model tools a grant can hold (the registry's closed catalog names
/// `spawn`, `tell` and `chiefs`; the brain adds `profile` from `self_edit`).
pub const MODEL_TOOLS: [&str; 4] = ["spawn", "tell", "profile", "chiefs"];

/// The env key of this host's turn key: the host gives it to its own turn
/// sessions only (session env, never a subagent's, never a preset or the
/// launcher file), and the tools socket answers `chiefs` only to a caller
/// that sends it.
// Not named *KEY*/*TOKEN*/*SECRET*: codex's default shell environment
// policy drops such names, and its `chief chiefs` call would lose it.
pub const TURN_KEY_ENV: &str = "OPTCHAT_TURN_SEAL";

/// The `chiefs` tool (name, description, input schema) for the MCP list.
pub use chief_kernel::tools::chiefs_tool;

/// This host process's turn seal: made once, given to its own turn
/// sessions only (their acpmux `session/new` env, brain/turns.rs), never to
/// a preset (acpmux keeps those readable) or a file.
pub fn process_turn_seal() -> &'static str {
    static SEAL: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    SEAL.get_or_init(fresh_turn_key)
}

fn new_turn_key() -> String {
    process_turn_seal().to_owned()
}

/// A fresh turn key: 32 random bytes, hex.
fn fresh_turn_key() -> String {
    use ring::rand::SecureRandom;
    let mut bytes = [0_u8; 32];
    // No randomness: an empty key, which no caller can match.
    if ring::rand::SystemRandom::new().fill(&mut bytes).is_err() {
        return String::new();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The `profile` tool (name, description, input schema) for the MCP list.
pub use chief_kernel::tools::profile_tool;

/// The largest picture `profile` sends (the registry's limit).
pub const MAX_AVATAR_BYTES: u64 = 1024 * 1024;

/// The fields of the record the brain uses.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    pub id: String,
    pub display_name: String,
    pub role: String,
    pub personality: String,
    pub instructions: String,
    pub tools: Vec<String>,
    pub harnesses: Vec<String>,
    pub self_edit: Vec<String>,
    pub is_default: bool,
    pub rev: u64,
}

impl Profile {
    pub fn from_wire(v: &Value) -> Option<Profile> {
        let text = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let list = |k: &str| -> Vec<String> {
            v.get(k)
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default()
        };
        let id = text("id");
        (!id.is_empty()).then(|| Profile {
            id,
            display_name: text("display_name"),
            role: text("role"),
            personality: text("personality"),
            instructions: text("instructions"),
            tools: list("tools"),
            harnesses: list("harnesses"),
            self_edit: list("self_edit"),
            is_default: v
                .get("is_default")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            rev: v.get("rev").and_then(Value::as_u64).unwrap_or(0),
        })
    }

    /// The profile sections of the system prompt, in the cloud brain's
    /// format (backend chief-brain/prompts.ts `systemPrompt`), always after
    /// the base rules. None for the default Chief with no profile text, so
    /// its prompt stays what it was before Chiefs had records.
    pub fn render(&self) -> Option<String> {
        chief_kernel::render_record(&chief_kernel::Record {
            display_name: self.display_name.clone(),
            role: self.role.clone(),
            personality: self.personality.clone(),
            instructions: self.instructions.clone(),
            is_default: self.is_default,
        })
    }
}

/// What this Chief may use: the record's grant, or everything when the
/// daemon has no registry (an older daemon, the cloud source).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grant {
    /// The granted model tools; None: every tool, no `profile` (no record).
    pub tools: Option<BTreeSet<String>>,
    /// The harnesses its subagents may run on; empty: every harness.
    pub harnesses: BTreeSet<String>,
}

impl Grant {
    pub fn all() -> Grant {
        Grant {
            tools: None,
            harnesses: BTreeSet::new(),
        }
    }

    pub fn from_profile(p: &Profile) -> Grant {
        let mut tools: BTreeSet<String> = MODEL_TOOLS
            .iter()
            .filter(|t| p.tools.iter().any(|g| g == *t))
            .map(|t| (*t).to_owned())
            .collect();
        if !p.self_edit.is_empty() {
            tools.insert("profile".to_owned());
        }
        Grant {
            tools: Some(tools),
            harnesses: p.harnesses.iter().cloned().collect(),
        }
    }

    /// Whether the model tool `tool` is granted (zoom, date and version always are).
    pub fn allows(&self, tool: &str) -> bool {
        match &self.tools {
            _ if matches!(tool, "zoom" | "date" | "version") => true,
            // No record: no profile and no chiefs (both need the registry).
            None => !matches!(tool, "profile" | "chiefs"),
            Some(set) => set.contains(tool),
        }
    }

    pub fn allows_harness(&self, harness: &str) -> bool {
        self.harnesses.is_empty() || self.harnesses.contains(harness)
    }

    /// The granted model tools in list order, comma separated, `none` for
    /// none; None when every tool is granted (no record).
    pub fn mcp_value(&self) -> Option<String> {
        self.tools.as_ref()?;
        let list: Vec<&str> = MODEL_TOOLS
            .iter()
            .copied()
            .filter(|t| self.allows(t))
            .collect();
        Some(if list.is_empty() {
            "none".to_owned()
        } else {
            list.join(",")
        })
    }

    /// Parses a `mcp_value` (None: every tool, as before records).
    pub fn from_mcp_value(value: Option<&str>) -> Grant {
        match value.map(str::trim) {
            None => Grant::all(),
            Some(v) => Grant {
                tools: Some(
                    v.split(',')
                        .map(str::trim)
                        .filter(|t| MODEL_TOOLS.contains(t))
                        .map(str::to_owned)
                        .collect(),
                ),
                harnesses: BTreeSet::new(),
            },
        }
    }

    /// The refusal for an ungranted tool (said to the model).
    pub fn refusal(tool: &str) -> String {
        format!(
            "The person has not given this Chief the {tool} tool. Ask them to add it \
(cmux chief edit <you> --tools ...) if the work needs it."
        )
    }
}

/// This Chief's record, grant and profile client, as the host serves them.
/// The record and grant can arrive after host start (a default Chief whose
/// daemon was away), so they sit behind a lock; the prompt keeps what it
/// rendered at start (byte-stable for the host's life).
#[derive(Debug)]
pub struct ChiefTools {
    state: std::sync::RwLock<Loaded>,
    client: Option<ProfileClient>,
    /// This host's turn key ([`TURN_KEY_ENV`]).
    turn_key: String,
}

#[derive(Clone, Debug)]
struct Loaded {
    profile: Option<Profile>,
    grant: Grant,
    /// The record is not read yet: zoom and date only until it is.
    pending: bool,
}

impl ChiefTools {
    /// No record: every tool as before, no profile tool.
    pub fn none() -> ChiefTools {
        ChiefTools {
            state: std::sync::RwLock::new(Loaded {
                profile: None,
                grant: Grant::all(),
                pending: false,
            }),
            client: None,
            turn_key: new_turn_key(),
        }
    }

    fn loaded(profile: Profile, client: ProfileClient) -> ChiefTools {
        ChiefTools {
            state: std::sync::RwLock::new(Loaded {
                grant: Grant::from_profile(&profile),
                profile: Some(profile),
                pending: false,
            }),
            client: Some(client),
            turn_key: new_turn_key(),
        }
    }

    /// Reads the record with `client` (None: the cloud source, no registry).
    /// Err when the daemon answers but has no such Chief or refuses.
    pub fn load(client: Option<ProfileClient>) -> Result<ChiefTools, LoadError> {
        let Some(client) = client else {
            return Ok(ChiefTools::none());
        };
        let profile = client.get()?;
        Ok(ChiefTools::loaded(profile, client))
    }

    /// The host's start: the record when the daemon answers; every tool when
    /// the registry has no record for this Chief or the daemon has no
    /// registry (as before records). Any other failure (the daemon away, a
    /// refused bind): a Chief that is not the default one does not start (its
    /// supervisor starts it again), so its grant never opens up; the default
    /// Chief starts with zoom and date only and reads the record when the
    /// daemon link comes up (`read_when_up`).
    pub fn start(
        client: Option<ProfileClient>,
        is_default: bool,
        log: &dyn Fn(String),
    ) -> Result<ChiefTools, String> {
        let Some(client) = client else {
            return Ok(ChiefTools::none());
        };
        match client.get() {
            Ok(profile) => {
                let tools = ChiefTools::loaded(profile, client);
                tools.log_record(log);
                Ok(tools)
            }
            Err(e @ (LoadError::NoRecord(_) | LoadError::NoRegistry(_))) => {
                log(format!("chief record: {e}; every tool, no profile"));
                Ok(ChiefTools::none())
            }
            Err(e) if is_default => {
                log(format!(
                    "chief record: not read ({e}); zoom and date only until the daemon answers"
                ));
                Ok(ChiefTools {
                    state: std::sync::RwLock::new(Loaded {
                        profile: None,
                        grant: Grant {
                            tools: Some(BTreeSet::new()),
                            harnesses: BTreeSet::new(),
                        },
                        pending: true,
                    }),
                    client: Some(client),
                    turn_key: new_turn_key(),
                })
            }
            Err(e) => Err(format!("reading this Chief's record: {e}")),
        }
    }

    fn log_record(&self, log: &dyn Fn(String)) {
        let state = self.read();
        if let Some(p) = &state.profile {
            log(format!(
                "chief record: {} {:?} rev {}, tools {:?}, harnesses {:?}, self_edit {:?}",
                p.id, p.display_name, p.rev, state.grant.tools, p.harnesses, p.self_edit
            ));
        }
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Loaded> {
        self.state
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether the record is still to be read (a default Chief whose daemon
    /// was away at host start).
    pub fn pending(&self) -> bool {
        self.read().pending
    }

    /// The daemon link is up (or a conversation changed): a pending record
    /// is read now. A record that is still not readable stays pending until
    /// the next link event.
    pub fn read_when_up(&self, log: &dyn Fn(String)) {
        if !self.pending() {
            return;
        }
        let Some(client) = &self.client else { return };
        let next = match client.get() {
            Ok(profile) => Loaded {
                grant: Grant::from_profile(&profile),
                profile: Some(profile),
                pending: false,
            },
            Err(e @ (LoadError::NoRecord(_) | LoadError::NoRegistry(_))) => {
                log(format!("chief record: {e}; every tool, no profile"));
                Loaded {
                    profile: None,
                    grant: Grant::all(),
                    pending: false,
                }
            }
            Err(e) => {
                log(format!(
                    "chief record: still not read ({e}); zoom and date only"
                ));
                return;
            }
        };
        *self
            .state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = next;
        self.log_record(log);
        log("chief record: the profile text reaches the prompt at the brain's next start".into());
    }

    /// The record as read (None: no record, or not read yet).
    pub fn profile(&self) -> Option<Profile> {
        self.read().profile.clone()
    }

    /// What this Chief may use now.
    pub fn grant(&self) -> Grant {
        self.read().grant.clone()
    }

    /// The host's instructions (the person's profile and files, the
    /// channels paragraph) followed by this Chief's profile sections.
    pub fn instructions(&self, base: Option<String>) -> Option<String> {
        let mine = self.profile().as_ref().and_then(Profile::render);
        match (base.filter(|b| !b.trim().is_empty()), mine) {
            (Some(base), Some(mine)) => Some(format!("{base}\n\n{mine}")),
            (base, mine) => base.or(mine),
        }
    }

    /// The model tools the `mcp` server lists (its `grant` question to the
    /// tools socket), comma separated, `none` for none.
    pub fn mcp_value(&self) -> String {
        self.grant()
            .mcp_value()
            .unwrap_or_else(|| "spawn,tell".to_owned())
    }

    /// This host's turn key, for its own turn sessions' presets only.
    pub fn turn_key(&self) -> &str {
        &self.turn_key
    }

    /// Whether `key` is this host's turn key (constant time; an empty key
    /// never matches).
    pub fn is_turn(&self, key: Option<&str>) -> bool {
        let (Some(key), mine) = (key, self.turn_key.as_bytes()) else {
            return false;
        };
        let key = key.as_bytes();
        if mine.is_empty() || key.len() != mine.len() {
            return false;
        }
        key.iter().zip(mine).fold(0_u8, |d, (a, b)| d | (a ^ b)) == 0
    }

    /// The `chiefs` tool: see, make and edit other Chiefs. The daemon checks
    /// the rules on this Chief's bound connection.
    pub fn chiefs_call(&self, args: &Value) -> Result<String, String> {
        if !self.grant().allows("chiefs") {
            return Err(Grant::refusal("chiefs"));
        }
        let client = self
            .client
            .as_ref()
            .ok_or("this Chief has no record here")?;
        client.manage(args)
    }

    /// The `profile` tool: read the record, or change the fields in `args`.
    pub fn profile_call(&self, args: &Value) -> Result<String, String> {
        if !self.grant().allows("profile") {
            return Err(Grant::refusal("profile"));
        }
        let client = self
            .client
            .as_ref()
            .ok_or("this Chief has no record here")?;
        client.apply(args)
    }
}

/// The daemon link's event sink, wrapped so a pending record is read each
/// time the link comes up (connected and bound) and on each conversation
/// change while it is still pending (a person's message reaches the brain
/// only after the read), before the brain hears the event.
pub fn read_record_on_up(
    tools: std::sync::Arc<ChiefTools>,
    sink: std::sync::Arc<dyn Fn(crate::daemon::DaemonEvent) + Send + Sync>,
    log: std::sync::Arc<dyn Fn(&str) + Send + Sync>,
) -> std::sync::Arc<dyn Fn(crate::daemon::DaemonEvent) + Send + Sync> {
    std::sync::Arc::new(move |event| {
        let link_event = matches!(
            event,
            crate::daemon::DaemonEvent::Up { .. } | crate::daemon::DaemonEvent::Changed { .. }
        );
        if link_event && tools.pending() {
            tools.read_when_up(&|line: String| log(&line));
        }
        sink(event)
    })
}

/// Why the record could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    /// The registry has no record for this participant (a Chief started
    /// before it had one, such as an instruction-file VM Chief, or one the
    /// person deleted): the daemon refuses its bound connection
    /// (`chief_registry_caller`) or answers `chief_not_found`.
    NoRecord(String),
    /// The daemon has no Chief registry (an older daemon refuses the v2
    /// envelope or the operation as invalid).
    NoRegistry(String),
    /// Anything else: the daemon away, the bind refused, a bad answer.
    Other(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::NoRecord(e) => write!(f, "no record: {e}"),
            LoadError::NoRegistry(e) => write!(f, "no registry: {e}"),
            LoadError::Other(e) => f.write_str(e),
        }
    }
}

impl LoadError {
    fn from_sdk(error: SdkError) -> LoadError {
        if let SdkError::Protocol { code, details, .. } = &error {
            let reasons = [
                details.get("reason"),
                details.get("extra").and_then(|x| x.get("reason")),
            ];
            let reason = |r: &str| reasons.iter().flatten().any(|v| v.as_str() == Some(r));
            if reason("chief_registry_caller") || reason("chief_not_found") {
                return LoadError::NoRecord(error.to_string());
            }
            if code == "validation.invalid" {
                return LoadError::NoRegistry(error.to_string());
            }
        }
        LoadError::Other(error.to_string())
    }
}

/// One bound connection's worth of settings: the daemon socket, the
/// participant token file and the Chief's id. Each call opens a fresh
/// connection (calls are rare: host start and `profile`).
#[derive(Clone, Debug)]
pub struct ProfileClient {
    socket: PathBuf,
    token_file: Option<PathBuf>,
    chief: String,
}

static KEYS: AtomicU64 = AtomicU64::new(0);

impl ProfileClient {
    pub fn new(socket: PathBuf, token_file: Option<PathBuf>, chief: String) -> ProfileClient {
        ProfileClient {
            socket,
            token_file,
            chief,
        }
    }

    fn connect(&self) -> Result<Client, String> {
        let mut client = Client::connect(ClientConfig::from_socket_path(&self.socket))
            .map_err(|e| format!("connecting to the daemon: {e}"))?;
        let token = crate::daemon::read_token(self.token_file.as_deref())
            .ok_or("MUX_AGENT_TOKEN_FILE is missing or empty")?;
        client
            .conversation_bind(ConversationBindRequest {
                participant: self.chief.clone(),
                token,
            })
            .map_err(|e| format!("binding as {}: {e}", self.chief))?;
        Ok(client)
    }

    fn v2(
        &self,
        operation: &str,
        mut params: Map<String, Value>,
        mutation: bool,
    ) -> Result<Value, SdkError> {
        params.insert("chief".into(), json!(self.chief));
        self.v2_raw(operation, params, mutation, None)
    }

    /// A v2 request on this Chief's bound connection with `params` as they
    /// are; `key` is the idempotency key of a mutation (None: a fresh one).
    fn v2_raw(
        &self,
        operation: &str,
        mut params: Map<String, Value>,
        mutation: bool,
        key: Option<String>,
    ) -> Result<Value, SdkError> {
        let mut client = self.connect().map_err(|e| SdkError::Protocol {
            code: "transport".into(),
            message: e,
            details: Value::Null,
            retryable: true,
        })?;
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        // A v2 request id is a string; a mutation's key is unique per call.
        let n = KEYS.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let unique = format!(
            "chief-profile-{}-{}-{nanos}-{n}",
            self.chief,
            std::process::id()
        );
        let mut frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": unique,
                               "operation": operation, "params": params});
        if mutation {
            frame["idempotency_key"] = json!(key.unwrap_or(unique));
        }
        let Value::Object(frame) = frame else {
            unreachable!("a JSON object")
        };
        let response = client.request_raw(frame)?;
        client.close();
        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }

    /// The Chief's record (`chief.profile.get`).
    pub fn get(&self) -> Result<Profile, LoadError> {
        let v = self
            .v2("chief.profile.get", Map::new(), false)
            .map_err(LoadError::from_sdk)?;
        Profile::from_wire(&v)
            .ok_or_else(|| LoadError::Other(format!("chief.profile.get answered no record: {v}")))
    }

    /// The `profile` tool's work (schemas/chief-profile/tool.json `answers`).
    pub fn apply(&self, args: &Value) -> Result<String, String> {
        let args = args.as_object().cloned().unwrap_or_default();
        let mut text = Map::new();
        for key in [
            "display_name",
            "role",
            "personality",
            "instructions",
            "harness",
            "model",
            "effort",
        ] {
            if let Some(v) = args.get(key) {
                let s = v
                    .as_str()
                    .ok_or(format!("profile: `{key}` must be a text"))?;
                text.insert(key.to_owned(), json!(s));
            }
        }
        let clear = args
            .get("clear_avatar")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let path = args
            .get("avatar_path")
            .and_then(Value::as_str)
            .map(str::trim);
        if let Some(unknown) = args.keys().find(|k| {
            !matches!(
                k.as_str(),
                "display_name"
                    | "role"
                    | "personality"
                    | "instructions"
                    | "harness"
                    | "model"
                    | "effort"
                    | "avatar_path"
                    | "clear_avatar"
                    | "history"
                    | "undo"
                    | "to_rev"
            )
        }) {
            return Err(format!("profile: no field {unknown}"));
        }
        let flag = |key: &str| args.get(key).and_then(Value::as_bool).unwrap_or(false);
        if flag("history") {
            let v = self
                .v2("chief.profile.history", Map::new(), false)
                .map_err(denied)?;
            return Ok(serde_json::to_string_pretty(&v).unwrap_or_default());
        }
        if flag("undo") {
            let mut p = Map::new();
            if let Some(rev) = args.get("to_rev").and_then(Value::as_u64) {
                p.insert("to_rev".into(), json!(rev));
            }
            let v = self.v2("chief.profile.undo", p, true).map_err(denied)?;
            let record = v.get("value").cloned().unwrap_or(v);
            return Ok(serde_json::to_string_pretty(&record).unwrap_or_default());
        }
        if clear && path.is_some() {
            return Err("profile: give avatar_path or clear_avatar, not both".to_owned());
        }
        let picture = match path {
            Some(p) => Some(read_picture(p)?),
            None => None,
        };
        if text.is_empty() && picture.is_none() && !clear {
            let v = self
                .v2("chief.profile.get", Map::new(), false)
                .map_err(denied)?;
            return Ok(serde_json::to_string_pretty(&v).unwrap_or_default());
        }
        let mut last = Value::Null;
        if !text.is_empty() {
            last = self
                .v2("chief.profile.update", text.clone(), true)
                .map_err(denied)?;
        }
        // A refused picture after a committed text change says both.
        let changed = |e: String| {
            if text.is_empty() {
                e
            } else {
                let fields: Vec<&str> = text.keys().map(String::as_str).collect();
                format!("{e} (Your {} did change.)", fields.join(", "))
            }
        };
        if let Some((media_type, bytes)) = picture {
            let mut p = Map::new();
            p.insert("media_type".into(), json!(media_type));
            p.insert(
                "data".into(),
                json!(base64::engine::general_purpose::STANDARD.encode(bytes)),
            );
            last = self
                .v2("chief.profile.avatar.set", p, true)
                .map_err(|e| changed(denied(e)))?;
        } else if clear {
            let mut p = Map::new();
            p.insert("clear".into(), json!(true));
            last = self
                .v2("chief.profile.avatar.set", p, true)
                .map_err(|e| changed(denied(e)))?;
        }
        let record = last.get("value").cloned().unwrap_or(last);
        Ok(format!(
            "{}\nYour picture shows at once and a changed backend (harness, model, effort) \
from your next turn. A changed name, role, personality or instructions reach your system \
prompt when your brain next starts.",
            serde_json::to_string_pretty(&record).unwrap_or_default()
        ))
    }
}

/// The fields `chiefs` create and update pass to the daemon.
const MANAGE_FIELDS: [&str; 10] = [
    "display_name",
    "role",
    "personality",
    "instructions",
    "tools",
    "harnesses",
    "self_edit",
    "harness",
    "model",
    "effort",
];

impl ProfileClient {
    /// The `chiefs` tool's work (schemas/chief-profile/chiefs-tool.json).
    pub fn manage(&self, args: &Value) -> Result<String, String> {
        let args = args.as_object().cloned().unwrap_or_default();
        if let Some(unknown) = args.keys().find(|k| {
            !MANAGE_FIELDS.contains(&k.as_str())
                && !matches!(
                    k.as_str(),
                    "action" | "chief" | "avatar_path" | "clear_avatar" | "to_rev"
                )
        }) {
            return Err(format!("chiefs: no field {unknown}"));
        }
        let action = args.get("action").and_then(Value::as_str).unwrap_or("list");
        let pretty = |v: &Value| serde_json::to_string_pretty(v).unwrap_or_default();
        let listed = || -> Result<Vec<Value>, String> {
            let v = self
                .v2_raw("chief.profile.list", Map::new(), false, None)
                .map_err(manage_denied)?;
            Ok(v.get("chiefs")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default())
        };
        let resolve = |records: &[Value]| -> Result<String, String> {
            let wanted = args
                .get("chief")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|w| !w.is_empty())
                .ok_or("chiefs: give chief, its id (agent_...) or its name")?;
            let field =
                |r: &Value, k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            if records.iter().any(|r| field(r, "id") == wanted) {
                return Ok(wanted.to_owned());
            }
            let named: Vec<String> = records
                .iter()
                .filter(|r| field(r, "display_name") == wanted)
                .map(|r| field(r, "id"))
                .collect();
            match named.as_slice() {
                [one] => Ok(one.clone()),
                [] => Err(format!("chiefs: no Chief is named {wanted}")),
                _ => Err(format!(
                    "chiefs: more than one Chief is named {wanted}; use its id"
                )),
            }
        };
        let fields: Map<String, Value> = args
            .iter()
            .filter(|(k, _)| MANAGE_FIELDS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let clear = args
            .get("clear_avatar")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let path = args
            .get("avatar_path")
            .and_then(Value::as_str)
            .map(str::trim);
        if clear && path.is_some() {
            return Err("chiefs: give avatar_path or clear_avatar, not both".to_owned());
        }
        match action {
            "list" => Ok(pretty(&Value::Array(listed()?))),
            "get" => {
                let id = resolve(&listed()?)?;
                let mut p = Map::new();
                p.insert("chief".into(), json!(id));
                let v = self
                    .v2_raw("chief.profile.get", p, false, None)
                    .map_err(manage_denied)?;
                Ok(pretty(&v))
            }
            "history" | "undo" => {
                let id = resolve(&listed()?)?;
                let mut p = Map::new();
                p.insert("chief".into(), json!(id));
                if action == "history" {
                    let v = self
                        .v2_raw("chief.profile.history", p, false, None)
                        .map_err(manage_denied)?;
                    return Ok(pretty(&v));
                }
                if let Some(rev) = args.get("to_rev").and_then(Value::as_u64) {
                    p.insert("to_rev".into(), json!(rev));
                }
                let v = self
                    .v2_raw("chief.profile.undo", p, true, None)
                    .map_err(manage_denied)?;
                Ok(pretty(&v.get("value").cloned().unwrap_or(v)))
            }
            "create" | "update" => {
                let picture = match path {
                    Some(p) => Some(read_picture(p)?),
                    None => None,
                };
                let (id, mut record) = if action == "create" {
                    if !fields.contains_key("display_name") {
                        return Err("chiefs: create needs display_name".to_owned());
                    }
                    let made = self
                        .v2_raw("chief.profile.create", fields.clone(), true, None)
                        .map_err(manage_denied)?;
                    let record = made.get("value").cloned().unwrap_or(made);
                    let id = record
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    (id, record)
                } else {
                    let id = resolve(&listed()?)?;
                    if fields.is_empty() && picture.is_none() && !clear {
                        return Err("chiefs: update needs at least one change".to_owned());
                    }
                    let mut record = Value::Null;
                    if !fields.is_empty() {
                        let mut p = fields.clone();
                        p.insert("chief".into(), json!(id));
                        let v = self
                            .v2_raw("chief.profile.update", p, true, None)
                            .map_err(manage_denied)?;
                        record = v.get("value").cloned().unwrap_or(v);
                    }
                    (id, record)
                };
                if picture.is_some() || clear {
                    let mut p = Map::new();
                    p.insert("chief".into(), json!(id));
                    match picture {
                        Some((media_type, bytes)) => {
                            p.insert("media_type".into(), json!(media_type));
                            p.insert(
                                "data".into(),
                                json!(base64::engine::general_purpose::STANDARD.encode(bytes)),
                            );
                        }
                        None => {
                            p.insert("clear".into(), json!(true));
                        }
                    }
                    let set = self
                        .v2_raw("chief.profile.avatar.set", p, true, None)
                        .map_err(|e| {
                            let e = manage_denied(e);
                            if record.is_null() {
                                e
                            } else {
                                format!("{e} (The other changes did commit.)")
                            }
                        })?;
                    // The create's brain outcome stays (the picture's answer has none).
                    let brain = record.get("brain").cloned();
                    record = set.get("value").cloned().unwrap_or(set);
                    if let (Some(brain), Some(fields)) = (brain, record.as_object_mut()) {
                        fields.insert("brain".into(), brain);
                    }
                }
                let note = if action == "create" {
                    brain_note(&record)
                } else {
                    "A changed name or picture shows at once; changed text reaches that Chief's \
system prompt when its brain next starts."
                };
                Ok(format!("{}\n{note}", pretty(&record)))
            }
            other => Err(format!(
                "chiefs: no action {other}; one of list, get, create, update, history, undo"
            )),
        }
    }
}

/// What the create answered about the new Chief's brain (the daemon's real
/// state), said plainly so the Chief tells the person the truth.
fn brain_note(record: &Value) -> &'static str {
    let brain = record.get("brain");
    let state = brain.and_then(|b| b.get("state")).and_then(Value::as_str);
    let reason = brain.and_then(|b| b.get("reason")).and_then(Value::as_str);
    match (state, reason) {
        (Some("started"), _) => {
            "Its brain started: it answers in its own conversation. Tell the person so."
        }
        (Some("not_started"), Some("no_supervisor")) => {
            "Its brain did NOT start: this cmux runs no Chief brains here (no supervisor). \
Tell the person plainly that the new Chief exists but will not answer until its brain runs."
        }
        (Some("not_started"), Some("launch_disabled")) => {
            "Its brain did NOT start: agents are turned off in this build session. Tell the \
person plainly that the new Chief exists but will not answer here."
        }
        (Some("not_started"), Some("unconfirmed")) => {
            "Whether its brain started is not confirmed yet (the supervisor was busy). Tell \
the person it may answer soon, and do not promise it."
        }
        (Some("not_started"), _) => {
            "Its brain did NOT start (an error; the daemon log says why). Tell the person \
plainly that the new Chief exists but will not answer until this is fixed."
        }
        _ => {
            "Whether its brain started is unknown (an older cmux). Do not tell the person it \
answers; say it was created."
        }
    }
}

/// The daemon's refusal of a `chiefs` call, phrased for the model.
fn manage_denied(error: SdkError) -> String {
    if let SdkError::Protocol {
        code,
        message,
        details,
        ..
    } = &error
    {
        let reason = details
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if code == "operation.failed" && !reason.is_empty() {
            let extra = details.get("extra").unwrap_or(details);
            let why = extra
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or(message);
            let fields: Vec<&str> = extra
                .get("fields")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            return if fields.is_empty() {
                format!("Not allowed ({reason}): {why}.")
            } else {
                format!("Not allowed ({reason}): {why} [{}].", fields.join(", "))
            };
        }
        if code == "validation.invalid" {
            return format!("chiefs: {message}");
        }
    }
    format!("chiefs: {error}")
}

const BAD_IMAGE: &str = "The picture must be a PNG, JPEG, GIF or WebP file of at most 1 MiB.";

/// The picture at `path`: its media type by its first bytes, and its bytes.
fn read_picture(path: &str) -> Result<(&'static str, Vec<u8>), String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("profile: reading {path}: {e}"))?;
    if !meta.is_file() || meta.len() > MAX_AVATAR_BYTES {
        return Err(BAD_IMAGE.to_owned());
    }
    let bytes = std::fs::read(path).map_err(|e| format!("profile: reading {path}: {e}"))?;
    let kind = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else {
        return Err(BAD_IMAGE.to_owned());
    };
    Ok((kind, bytes))
}

/// The daemon's refusal, phrased for the model.
fn denied(error: SdkError) -> String {
    if let SdkError::Protocol {
        code,
        message,
        details,
        ..
    } = &error
    {
        let reason = details
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if reason == "chief_self_edit_denied" {
            // operation.failed puts the handler's own details under `extra`.
            let extra = details.get("extra").unwrap_or(details);
            let fields: Vec<&str> = extra
                .get("fields")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            if fields.is_empty() {
                let why = extra
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or(message);
                return format!("Not allowed: {why}.");
            }
            return format!(
                "Not allowed: {}. Ask the person to change them, or to add them to your self_edit.",
                fields.join(", ")
            );
        }
        if code == "validation.invalid" {
            return format!("profile: {message}");
        }
    }
    format!("profile: {error}")
}
