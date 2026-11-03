//! Per-person rights on the Chief's host (multiplayer Chief, cmuxterm-hq
//! `plans/multiplayer-chief/DESIGN.md` section 5).
//!
//! A turn that carries the text of someone other than the Chief's owner runs
//! under the ask floor (README "Remote-origin messages"): every local effect
//! is refused. The rights table lets the owner open that floor one tool at a
//! time, per person: `$MUX_HOME/optchat/rights.json` (0600).
//!
//! ```json
//! {"version": 1,
//!  "chief_cap_usd_day": 20.0,
//!  "people": {
//!    "user_ben": {"name": "Ben", "allow": ["Read", "Bash(git status*)"],
//!                 "cap_usd_day": 2.0},
//!    "user_ana": {"name": "Ana", "approver": true},
//!    "chief:ben-chief": {"name": "Ben's Chief", "owner": "user_ben",
//!                        "allow": ["WebFetch"]}}}
//! ```
//!
//! - A person is a conversation participant id (`user_<account>`), or
//!   `chief:<name>` for another person's Chief (peer_chiefs.rs).
//! - `allow` holds tool patterns ([`Pattern`]). A turn may run a call only
//!   when every person whose text it carries is allowed it; the owner and
//!   approvers count as allowed for everything.
//! - `approver` (granted by the owner only): the person's word authorizes
//!   effects as the owner's does, so their turn runs without the floor.
//! - `cap_usd_day` and `chief_cap_usd_day`: spend caps per local day
//!   (usage.rs ledger), enforced when a turn would start.
//! - `auth`: what the Chief's own model login is ([`AuthKind`]). Watching is
//!   always allowed, but another person's prompt runs on the owner's login,
//!   so it runs only on commercial auth (an API key, Bedrock, Vertex,
//!   Foundry, or a Team or Enterprise seat), and only for a person the
//!   owner listed here (their org or team). On a personal subscription (Pro,
//!   Max, ChatGPT Plus or Pro) or an unknown login, another person's message
//!   is a suggestion: the Chief runs no turn for it and the owner may send it
//!   as their own ([`Rights::may_prompt`]). Anthropic's Consumer Terms forbid
//!   making an account available to anyone else; the Commercial Terms let a
//!   key serve the customer's own authorized users. A Chief-to-Chief request
//!   is held to the same rule on the receiving Chief's login.
//! - No file, or a person with no entry: nothing beyond today's floor.
//! - The host's own files (this table, the audit log) are never writable
//!   through a grant: [`Rights::decide`] refuses an edit there whatever the
//!   table says.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The table's file name in the optchat root.
pub const FILE: &str = "rights.json";
/// The format version written.
pub const VERSION: u32 = 1;
/// The id prefix of another person's Chief.
pub const CHIEF_PREFIX: &str = "chief:";

/// The kind of model login the Chief's turns run on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthKind {
    /// An Anthropic or OpenAI API key billed to its owner.
    ApiKey,
    Bedrock,
    Vertex,
    Foundry,
    /// A Team or Enterprise organization seat.
    Team,
    Enterprise,
    /// A personal subscription (Claude Pro, Max, Ultra; ChatGPT Plus, Pro).
    Personal,
}

impl AuthKind {
    pub fn parse(s: &str) -> Option<AuthKind> {
        serde_json::from_value(Value::String(s.to_owned())).ok()
    }

    pub fn as_str(self) -> &'static str {
        match self {
            AuthKind::ApiKey => "api-key",
            AuthKind::Bedrock => "bedrock",
            AuthKind::Vertex => "vertex",
            AuthKind::Foundry => "foundry",
            AuthKind::Team => "team",
            AuthKind::Enterprise => "enterprise",
            AuthKind::Personal => "personal",
        }
    }

    /// Whether it may serve people other than its owner.
    pub fn commercial(self) -> bool {
        !matches!(self, AuthKind::Personal)
    }

    /// What an environment says, when it says it plainly: an API key or a
    /// cloud provider switch is commercial. A subscription login is not
    /// visible here, so None (the table's own `auth`, else personal).
    pub fn detect(env: &dyn Fn(&str) -> Option<String>) -> Option<AuthKind> {
        let set = |k: &str| env(k).is_some_and(|v| !v.trim().is_empty() && v != "0");
        if set("CLAUDE_CODE_USE_BEDROCK") {
            Some(AuthKind::Bedrock)
        } else if set("CLAUDE_CODE_USE_VERTEX") {
            Some(AuthKind::Vertex)
        } else if set("CLAUDE_CODE_USE_FOUNDRY") {
            Some(AuthKind::Foundry)
        } else if set("ANTHROPIC_API_KEY") {
            Some(AuthKind::ApiKey)
        } else {
            None
        }
    }
}

/// One person's entry.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Person {
    /// What people call them (shown in `/rights` and `/audit`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Their word authorizes effects as the owner's does.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub approver: bool,
    /// Tool patterns they may trigger ([`Pattern`]).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allow: Vec<String>,
    /// Their spend cap per local day, in USD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cap_usd_day: Option<f64>,
    /// For a Chief (`chief:<name>`): the person it acts for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
}

/// The rights table.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rights {
    #[serde(default)]
    pub version: u32,
    /// The Chief's model login, as the owner declared it (None: personal).
    /// The host does not guess it from its own environment: the turns run
    /// on their harness's login, which may differ.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<AuthKind>,
    /// The Chief's own spend cap per local day, in USD (every turn counts).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chief_cap_usd_day: Option<f64>,
    #[serde(default)]
    pub people: BTreeMap<String, Person>,
}

/// Why a call was allowed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Allowed {
    /// Only the owner (or nobody) wrote in the turn.
    Owner,
    /// Every other author is an approver.
    Approver,
    /// Every other author holds a grant that matches; the patterns used.
    Grant(Vec<String>),
}

/// The answer for one call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Allow(Allowed),
    /// `who` may not run it; `why` says so in a few words.
    Deny { who: String, why: String },
}

impl Decision {
    pub fn allowed(&self) -> bool {
        matches!(self, Decision::Allow(_))
    }

    /// A short label for the audit log (`owner`, `approver`, `grant:<p>`, `deny`).
    pub fn by(&self) -> String {
        match self {
            Decision::Allow(Allowed::Owner) => "owner".into(),
            Decision::Allow(Allowed::Approver) => "approver".into(),
            Decision::Allow(Allowed::Grant(p)) => format!("grant:{}", p.join(",")),
            Decision::Deny { .. } => "deny".into(),
        }
    }
}

impl Rights {
    /// The table's path under the optchat root.
    pub fn path(optchat_root: &Path) -> PathBuf {
        optchat_root.join(FILE)
    }

    /// Reads the table; a missing file is an empty table. A file that does not
    /// parse is an error (the caller fails closed: no grants).
    pub fn load(path: &Path) -> Result<Rights, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let rights: Rights = serde_json::from_str(&text)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                for (who, person) in &rights.people {
                    for p in &person.allow {
                        Pattern::parse(p).map_err(|e| format!("{who}: {e}"))?;
                    }
                }
                Ok(rights)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Rights::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    /// Writes the table atomically (a 0600 temp file renamed over it).
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let mut out = self.clone();
        out.version = VERSION;
        let text = serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?;
        let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
        let write = || -> std::io::Result<()> {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            f.write_all(text.as_bytes())?;
            f.write_all(b"\n")?;
            f.sync_all()?;
            std::fs::rename(&tmp, path)
        };
        write().map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The login the Chief's turns run on: the declared one, else what the
    /// environment shows, else personal (fail closed).
    pub fn auth_kind(&self, detected: Option<AuthKind>) -> AuthKind {
        self.auth.or(detected).unwrap_or(AuthKind::Personal)
    }

    /// Whether `author`'s prompt may start a turn on this Chief's login.
    /// Err: why it is only a suggestion (shown to the people in the chat).
    pub fn may_prompt(
        &self,
        owner: &str,
        author: &str,
        detected: Option<AuthKind>,
    ) -> Result<(), String> {
        if author == owner {
            return Ok(());
        }
        let auth = self.auth_kind(detected);
        if !auth.commercial() {
            return Err(format!(
                "this Chief runs on its owner's personal subscription ({}), which may not serve anyone else: \
                 the message is a suggestion for its owner to send as their own",
                auth.as_str()
            ));
        }
        if self.person(author).is_none() {
            return Err(format!(
                "{author} is not on this Chief's team list: only people its owner added may prompt it on its {} login",
                auth.as_str()
            ));
        }
        Ok(())
    }

    pub fn person(&self, id: &str) -> Option<&Person> {
        self.people.get(id)
    }

    /// The name to show for `id`.
    pub fn name_of<'a>(&'a self, id: &'a str) -> &'a str {
        self.person(id)
            .and_then(|p| p.name.as_deref())
            .unwrap_or(id)
    }

    pub fn is_approver(&self, id: &str) -> bool {
        self.person(id).is_some_and(|p| p.approver)
    }

    /// Whether a turn that carries text of each of `authors` runs without the
    /// floor: every author is the owner or an approver. A Chief is never an
    /// approver (its owner's word reaches us only through it).
    pub fn lifts_floor(&self, owner: &str, authors: &[String]) -> bool {
        authors
            .iter()
            .all(|a| a == owner || (!a.starts_with(CHIEF_PREFIX) && self.is_approver(a)))
    }

    /// Whether a turn whose text came from each of `authors` may run `tool`
    /// with `input` on this host. `protected` are the host's own files that no
    /// grant may write (the table, the audit log).
    pub fn decide(
        &self,
        owner: &str,
        authors: &[String],
        tool: &str,
        input: Option<&Value>,
        protected: &[PathBuf],
    ) -> Decision {
        let others: Vec<&String> = authors.iter().filter(|a| *a != owner).collect();
        if others.is_empty() {
            return Decision::Allow(Allowed::Owner);
        }
        if writes_protected(tool, input, protected) {
            return Decision::Deny {
                who: others[0].clone(),
                why: "the Chief's rights and audit files are never writable through a grant"
                    .into(),
            };
        }
        if self.lifts_floor(owner, authors) {
            return Decision::Allow(Allowed::Approver);
        }
        let mut used = Vec::new();
        for who in others {
            if !who.starts_with(CHIEF_PREFIX) && self.is_approver(who) {
                continue;
            }
            let Some(person) = self.person(who) else {
                return Decision::Deny {
                    who: who.clone(),
                    why: "no rights on this Chief".into(),
                };
            };
            let hit = person.allow.iter().find(|p| {
                Pattern::parse(p).is_ok_and(|pat| pat.matches(tool, input))
            });
            match hit {
                Some(p) => {
                    if !used.contains(p) {
                        used.push(p.clone());
                    }
                }
                None => {
                    return Decision::Deny {
                        who: who.clone(),
                        why: format!("{} is not in their allowlist", short_tool(tool)),
                    };
                }
            }
        }
        Decision::Allow(Allowed::Grant(used))
    }

    /// Adds `patterns` to `who`'s allowlist (each checked first).
    pub fn grant(&mut self, who: &str, patterns: &[String]) -> Result<(), String> {
        for p in patterns {
            Pattern::parse(p)?;
        }
        let person = self.people.entry(who.to_owned()).or_default();
        for p in patterns {
            if !person.allow.contains(p) {
                person.allow.push(p.clone());
            }
        }
        Ok(())
    }

    /// Removes `patterns` from `who`'s allowlist; none given: every grant
    /// and the approver right. Answers whether anything changed.
    pub fn revoke(&mut self, who: &str, patterns: &[String]) -> bool {
        let Some(person) = self.people.get_mut(who) else {
            return false;
        };
        let before = (person.allow.len(), person.approver);
        if patterns.is_empty() {
            person.allow.clear();
            person.approver = false;
        } else {
            person.allow.retain(|p| !patterns.contains(p));
        }
        before != (person.allow.len(), person.approver)
    }

    /// Sets or clears `who`'s approver right (the owner only: the caller checks).
    pub fn set_approver(&mut self, who: &str, on: bool) -> Result<(), String> {
        if who.starts_with(CHIEF_PREFIX) && on {
            return Err("a Chief cannot be an approver; grant its tools instead".into());
        }
        self.people.entry(who.to_owned()).or_default().approver = on;
        Ok(())
    }
}

/// One allowlist entry.
///
/// - `Tool`: the tool by name with any input (`Read`, `WebFetch`,
///   `mcp__github__get_issue`). `Bash` alone allows any shell command, which
///   is as much as the owner's own word: grant it only to an approver.
/// - `mcp__server__*`: every tool of one MCP server.
/// - `Bash(prefix*)`: a shell command that starts with `prefix` and chains
///   nothing (no `;`, `&`, `|`, backtick, `$(`, `>`, `<` or line break);
///   `Bash(cmd)` without `*` is that exact command.
/// - `Read(/dir/*)`, `Edit(/dir/*)`, `Write(/dir/*)`, `Glob(..)`, `Grep(..)`:
///   a path under `/dir` (no `..` after normalizing); without `*`, that file.
/// - `WebFetch(https://host/*)`: a URL with that prefix.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pattern {
    tool: String,
    arg: Option<Arg>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Arg {
    Exact(String),
    Prefix(String),
}

/// Characters that chain or redirect a shell command.
const SHELL_META: [&str; 9] = [";", "&", "|", "`", "$(", ">", "<", "\n", "\r"];

impl Pattern {
    pub fn parse(text: &str) -> Result<Pattern, String> {
        let text = text.trim();
        let bad = || format!("bad tool pattern {text:?}");
        if text.is_empty() {
            return Err(bad());
        }
        let (tool, arg) = match text.find('(') {
            None => (text, None),
            Some(i) => {
                let inner = text[i + 1..].strip_suffix(')').ok_or_else(bad)?;
                if inner.is_empty() {
                    return Err(bad());
                }
                let arg = match inner.strip_suffix('*') {
                    Some(p) if !p.is_empty() => Arg::Prefix(p.to_owned()),
                    Some(_) => return Err(format!("{text:?}: write `{}` for any input", &text[..i])),
                    None => Arg::Exact(inner.to_owned()),
                };
                (&text[..i], Some(arg))
            }
        };
        let tool_ok = tool
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '*');
        if !tool_ok || tool.is_empty() {
            return Err(bad());
        }
        if tool.contains('*') && !(tool.starts_with("mcp__") && tool.ends_with("__*")) {
            return Err(format!("{text:?}: only `mcp__<server>__*` may use a wildcard in the tool"));
        }
        if arg.is_some() && arg_key(tool).is_none() {
            return Err(format!("{text:?}: {tool} takes no argument pattern"));
        }
        if let (Some(Arg::Prefix(p) | Arg::Exact(p)), Some(ArgKind::Path)) = (&arg, arg_kind(tool)) {
            if !p.starts_with('/') {
                return Err(format!("{text:?}: a path pattern must be absolute"));
            }
        }
        Ok(Pattern {
            tool: tool.to_owned(),
            arg,
        })
    }

    pub fn matches(&self, tool: &str, input: Option<&Value>) -> bool {
        let tool_hit = match self.tool.strip_suffix('*') {
            Some(prefix) => tool.starts_with(prefix),
            None => self.tool == tool,
        };
        if !tool_hit {
            return false;
        }
        let Some(arg) = &self.arg else {
            return true;
        };
        let Some(value) = arg_key(tool)
            .and_then(|k| input.and_then(|i| i.get(k)))
            .and_then(Value::as_str)
        else {
            return false;
        };
        match arg_kind(tool) {
            Some(ArgKind::Command) => {
                if SHELL_META.iter().any(|m| value.contains(m)) {
                    return false;
                }
                let value = value.trim();
                match arg {
                    Arg::Exact(e) => value == e.trim(),
                    Arg::Prefix(p) => value.starts_with(p.as_str()),
                }
            }
            Some(ArgKind::Path) => {
                // Symlinks resolved, so a link under a granted directory
                // does not reach a file outside it.
                let Some(path) = normalize(value).map(|p| resolve(&p)) else {
                    return false;
                };
                match arg {
                    Arg::Exact(e) => normalize(e).is_some_and(|e| resolve(&e) == path),
                    // `/dir/*`: anything under the directory, by component.
                    Arg::Prefix(p) if p.ends_with('/') => {
                        normalize(p)
                            .map(|d| resolve(&d))
                            .is_some_and(|dir| path.starts_with(&dir) && path != dir)
                    }
                    // `/dir/name*`: the normalized path's text starts so.
                    Arg::Prefix(p) => path.to_string_lossy().starts_with(p.as_str()),
                }
            }
            Some(ArgKind::Url) => match arg {
                Arg::Exact(e) => value == e,
                Arg::Prefix(p) => value.starts_with(p.as_str()),
            },
            None => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ArgKind {
    Command,
    Path,
    Url,
}

fn arg_kind(tool: &str) -> Option<ArgKind> {
    match tool {
        "Bash" => Some(ArgKind::Command),
        "Read" | "Edit" | "MultiEdit" | "Write" | "NotebookEdit" | "Glob" | "Grep" => {
            Some(ArgKind::Path)
        }
        "WebFetch" => Some(ArgKind::Url),
        _ => None,
    }
}

/// The input field a pattern's argument is matched against.
fn arg_key(tool: &str) -> Option<&'static str> {
    match tool {
        "Bash" => Some("command"),
        "Read" | "Edit" | "MultiEdit" | "Write" => Some("file_path"),
        "NotebookEdit" => Some("notebook_path"),
        "Glob" | "Grep" => Some("path"),
        "WebFetch" => Some("url"),
        _ => None,
    }
}

/// `path` with `.` dropped and `..` refused (None), absolute only.
fn normalize(path: &str) -> Option<PathBuf> {
    let p = Path::new(path);
    if !p.is_absolute() {
        return None;
    }
    let mut out = PathBuf::from("/");
    for c in p.components() {
        match c {
            Component::RootDir | Component::CurDir => {}
            Component::Normal(n) => out.push(n),
            Component::ParentDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// `path` (normalized) with its longest existing ancestor's symlinks resolved.
fn resolve(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut at = path.to_path_buf();
    loop {
        if let Ok(real) = at.canonicalize() {
            let mut out = real;
            for part in rest.iter().rev() {
                out.push(part);
            }
            return out;
        }
        match (at.file_name().map(|n| n.to_owned()), at.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                at = parent.to_path_buf();
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// Whether the call writes one of `protected` (a file or a directory).
fn writes_protected(tool: &str, input: Option<&Value>, protected: &[PathBuf]) -> bool {
    if !matches!(tool, "Edit" | "MultiEdit" | "Write" | "NotebookEdit") {
        return false;
    }
    let Some(path) = arg_key(tool)
        .and_then(|k| input.and_then(|i| i.get(k)))
        .and_then(Value::as_str)
    else {
        return false;
    };
    // An unnormalizable path is refused by every pattern anyway.
    let Some(path) = normalize(path) else {
        return false;
    };
    let resolved = resolve(&path);
    protected.iter().any(|p| {
        let real = resolve(p);
        path.starts_with(p) || resolved.starts_with(&real) || resolved.starts_with(p)
    })
}

/// `mcp__optchat__send` as `send`, `Bash` as `Bash`.
fn short_tool(tool: &str) -> &str {
    tool.rsplit("__").next().unwrap_or(tool)
}

/// Adds the rights hook to a turn folder's project `settings`: before and
/// after every tool call, `<exe> rights-hook pre|post --socket <socket>`
/// asks the host (brain/rights_gate.rs). Hooks turn on; the user's named
/// hooks (turn_user_extras.rs) stay.
pub fn add_turn_hooks(settings: &mut Value, exe: &str, socket: &Path) {
    let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
    for (event, phase) in [("PreToolUse", "pre"), ("PostToolUse", "post")] {
        let command = format!(
            "{} rights-hook {phase} --socket {}",
            quote(exe),
            quote(&socket.display().to_string())
        );
        let group = serde_json::json!({
            "matcher": "*",
            "hooks": [{"type": "command", "command": command, "timeout": 15}],
        });
        if !settings["hooks"].is_object() {
            settings["hooks"] = serde_json::json!({});
        }
        match settings["hooks"][event].as_array_mut() {
            Some(groups) => groups.insert(0, group),
            None => settings["hooks"][event] = serde_json::json!([group]),
        }
    }
    settings["disableAllHooks"] = serde_json::json!(false);
}

/// `optchat-chief rights-hook pre|post --socket PATH`: Claude Code's hook
/// input on stdin, the host's answer on stdout. A host that does not answer
/// gives no decision, so the call reaches the turn's own policy (the ask
/// floor refuses it in another person's turn).
pub fn hook(phase: &str, socket: &Path, stdin: &mut dyn std::io::Read) -> String {
    let mut text = String::new();
    if stdin.read_to_string(&mut text).is_err() {
        return String::new();
    }
    let Ok(payload) = serde_json::from_str::<Value>(&text) else {
        return String::new();
    };
    match crate::tools::ask_rights_hook(socket, phase, payload) {
        Ok(answer) if answer != "{}" => answer,
        _ => String::new(),
    }
}

/// `optchat-chief rights ...`: show and edit the table from a terminal (the
/// owner's own; the chat's `/grant` and `/revoke` go through the host).
///
/// ```text
/// optchat-chief rights [show] [--json]
/// optchat-chief rights grant PERSON PATTERN...
/// optchat-chief rights revoke PERSON [PATTERN...]
/// optchat-chief rights approver PERSON on|off
/// optchat-chief rights cap PERSON USD|off
/// optchat-chief rights chief-cap USD|off
/// optchat-chief rights auth api-key|bedrock|vertex|foundry|team|enterprise|personal|auto
/// optchat-chief rights name PERSON NAME
/// optchat-chief rights check PERSON TOOL [INPUT_JSON]
/// ```
pub fn run(words: &[String], optchat_root: &Path, owner: &str) -> Result<String, String> {
    let path = Rights::path(optchat_root);
    let mut rights = Rights::load(&path)?;
    let json = words.iter().any(|w| w == "--json");
    let words: Vec<&str> = words
        .iter()
        .map(String::as_str)
        .filter(|w| *w != "--json")
        .collect();
    let usd = |s: &str| -> Result<Option<f64>, String> {
        if s == "off" {
            return Ok(None);
        }
        let v: f64 = s
            .trim_start_matches('$')
            .parse()
            .map_err(|_| format!("not an amount: {s}"))?;
        if !v.is_finite() || v < 0.0 {
            return Err(format!("not an amount: {s}"));
        }
        Ok(Some(v))
    };
    let changed = match words.as_slice() {
        [] | ["show"] => {
            return Ok(if json {
                serde_json::to_string_pretty(&rights).map_err(|e| e.to_string())?
            } else {
                render(&rights)
            });
        }
        ["grant", who, patterns @ ..] if !patterns.is_empty() => {
            let patterns: Vec<String> = patterns.iter().map(|s| s.to_string()).collect();
            rights.grant(who, &patterns)?;
            format!("{who} may now use {}", patterns.join(", "))
        }
        ["revoke", who, patterns @ ..] => {
            let patterns: Vec<String> = patterns.iter().map(|s| s.to_string()).collect();
            if !rights.revoke(who, &patterns) {
                return Ok(format!("{who}: nothing to revoke"));
            }
            format!("{who}: revoked {}", if patterns.is_empty() { "everything".into() } else { patterns.join(", ") })
        }
        ["approver", who, on @ ("on" | "off")] => {
            rights.set_approver(who, *on == "on")?;
            format!("{who} is {}an approver", if *on == "on" { "" } else { "no longer " })
        }
        ["cap", who, amount] => {
            rights.people.entry(who.to_string()).or_default().cap_usd_day = usd(amount)?;
            format!("{who}: daily cap {amount}")
        }
        ["auth", kind] => {
            rights.auth = match *kind {
                "auto" => None,
                k => Some(AuthKind::parse(k).ok_or_else(|| {
                    format!("auth is one of api-key, bedrock, vertex, foundry, team, enterprise, personal, auto (not {k})")
                })?),
            };
            format!("Chief login: {kind}")
        }
        ["chief-cap", amount] => {
            rights.chief_cap_usd_day = usd(amount)?;
            format!("Chief daily cap {amount}")
        }
        ["name", who, name @ ..] if !name.is_empty() => {
            rights.people.entry(who.to_string()).or_default().name = Some(name.join(" "));
            format!("{who} is {}", name.join(" "))
        }
        ["check", who, tool, rest @ ..] => {
            let input: Option<Value> = match rest {
                [] => None,
                [j] => Some(serde_json::from_str(j).map_err(|e| format!("input: {e}"))?),
                _ => return Err("check PERSON TOOL [INPUT_JSON]".into()),
            };
            let d = rights.decide(owner, &[who.to_string()], tool, input.as_ref(), &[]);
            return Ok(match d {
                Decision::Allow(_) => format!("allow ({})", d.by()),
                Decision::Deny { who, why } => format!("deny: {who}: {why}"),
            });
        }
        _ => return Err(USAGE.into()),
    };
    rights.save(&path)?;
    Ok(changed)
}

pub const USAGE: &str = "usage: rights [show] [--json] | grant PERSON PATTERN... | revoke PERSON [PATTERN...] | approver PERSON on|off | cap PERSON USD|off | chief-cap USD|off | auth KIND|auto | name PERSON NAME | check PERSON TOOL [INPUT_JSON]";

/// The table as lines for a person to read (the auth this process sees).
pub fn render(rights: &Rights) -> String {
    render_with(rights, rights.auth_kind(None))
}

/// [`render`] with the Chief's login `auth`.
pub fn render_with(rights: &Rights, auth: AuthKind) -> String {
    let mut out = Vec::new();
    out.push(format!(
        "Login: {}{}",
        auth.as_str(),
        if auth.commercial() {
            " (people listed here may prompt it)"
        } else {
            " (personal: other people's messages are suggestions only)"
        }
    ));
    out.push(match rights.chief_cap_usd_day {
        Some(c) => format!("Chief daily cap: ${c:.2}"),
        None => "Chief daily cap: none".to_owned(),
    });
    if rights.people.is_empty() {
        out.push("Nobody but the owner has rights on this Chief.".to_owned());
    }
    for (id, p) in &rights.people {
        let mut line = format!("- {}", p.name.as_deref().map_or(id.clone(), |n| format!("{n} ({id})")));
        if p.approver {
            line.push_str(": approver");
        } else if p.allow.is_empty() {
            line.push_str(": no tools");
        } else {
            line.push_str(&format!(": {}", p.allow.join(", ")));
        }
        if let Some(c) = p.cap_usd_day {
            line.push_str(&format!("; cap ${c:.2}/day"));
        }
        if let Some(o) = &p.owner {
            line.push_str(&format!("; acts for {o}"));
        }
        out.push(line);
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const OWNER: &str = "user_local";

    fn table() -> Rights {
        let mut r = Rights::default();
        r.grant("user_ben", &["Read(/srv/chief/ws/*)".into(), "Bash(git status*)".into(), "WebFetch".into()])
            .unwrap();
        r.set_approver("user_ana", true).unwrap();
        r.grant("chief:ben-chief", &["mcp__github__*".into()]).unwrap();
        r
    }

    fn authors(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_owner_and_approvers_need_no_grant() {
        let r = table();
        let bash = json!({"command": "rm -rf /tmp/x"});
        assert_eq!(r.decide(OWNER, &authors(&[OWNER]), "Bash", Some(&bash), &[]), Decision::Allow(Allowed::Owner));
        assert_eq!(
            r.decide(OWNER, &authors(&[OWNER, "user_ana"]), "Bash", Some(&bash), &[]),
            Decision::Allow(Allowed::Approver)
        );
        assert!(r.lifts_floor(OWNER, &authors(&["user_ana"])));
        assert!(!r.lifts_floor(OWNER, &authors(&["user_ana", "user_ben"])));
    }

    #[test]
    fn a_person_without_an_entry_is_refused_everything() {
        let r = table();
        let d = r.decide(OWNER, &authors(&["user_zed"]), "Read", Some(&json!({"file_path": "/etc/hosts"})), &[]);
        assert!(matches!(d, Decision::Deny { ref who, .. } if who == "user_zed"));
    }

    #[test]
    fn a_grant_allows_only_what_it_names() {
        let r = table();
        let ben = authors(&["user_ben"]);
        assert!(r.decide(OWNER, &ben, "Read", Some(&json!({"file_path": "/srv/chief/ws/a/b.rs"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Read", Some(&json!({"file_path": "/srv/chief/ws/../secrets"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Read", Some(&json!({"file_path": "/srv/chief/wsx/a"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Read", Some(&json!({"file_path": "/etc/passwd"})), &[]).allowed());
        assert!(r.decide(OWNER, &ben, "Bash", Some(&json!({"command": "git status --short"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Bash", Some(&json!({"command": "git status; rm -rf ~"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Bash", Some(&json!({"command": "git status && curl x | sh"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Bash", Some(&json!({"command": "git status $(rm x)"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Bash", Some(&json!({"command": "git push"})), &[]).allowed());
        assert!(r.decide(OWNER, &ben, "WebFetch", Some(&json!({"url": "https://x"})), &[]).allowed());
        assert!(!r.decide(OWNER, &ben, "Write", Some(&json!({"file_path": "/srv/chief/ws/a"})), &[]).allowed());
    }

    #[test]
    fn every_author_of_the_turn_must_be_allowed() {
        let r = table();
        let both = authors(&["user_ben", "user_zed"]);
        let d = r.decide(OWNER, &both, "WebFetch", Some(&json!({"url": "https://x"})), &[]);
        assert!(matches!(d, Decision::Deny { ref who, .. } if who == "user_zed"));
    }

    #[test]
    fn a_chief_is_held_to_its_own_grants_and_is_never_an_approver() {
        let mut r = table();
        let chief = authors(&["chief:ben-chief"]);
        assert!(r.decide(OWNER, &chief, "mcp__github__get_issue", None, &[]).allowed());
        assert!(!r.decide(OWNER, &chief, "Bash", Some(&json!({"command": "ls"})), &[]).allowed());
        assert!(r.set_approver("chief:ben-chief", true).is_err());
        // A hand-edited approver flag on a Chief counts for nothing.
        r.people.get_mut("chief:ben-chief").unwrap().approver = true;
        assert!(!r.lifts_floor(OWNER, &chief));
        assert!(!r.decide(OWNER, &chief, "Bash", Some(&json!({"command": "ls"})), &[]).allowed());
    }

    #[test]
    fn no_grant_writes_the_hosts_own_files() {
        let mut r = table();
        r.grant("user_ben", &["Write(/srv/chief/*)".into()]).unwrap();
        let protected = vec![PathBuf::from("/srv/chief/optchat")];
        let ben = authors(&["user_ben"]);
        assert!(r.decide(OWNER, &ben, "Write", Some(&json!({"file_path": "/srv/chief/ws/a"})), &protected).allowed());
        assert!(!r.decide(OWNER, &ben, "Write", Some(&json!({"file_path": "/srv/chief/optchat/rights.json"})), &protected).allowed());
        assert!(!r.decide(OWNER, &ben, "Write", Some(&json!({"file_path": "/srv/chief/./optchat/audit/audit.jsonl"})), &protected).allowed());
    }

    #[test]
    fn another_persons_prompt_needs_commercial_auth_and_a_listed_person() {
        let mut r = table();
        // Personal (the default, and what an unknown login counts as).
        assert!(r.may_prompt(OWNER, OWNER, None).is_ok());
        assert!(r.may_prompt(OWNER, "user_ben", None).unwrap_err().contains("suggestion"));
        assert!(r.may_prompt(OWNER, "user_ana", None).is_err(), "an approver too");
        // The environment shows an API key.
        assert!(r.may_prompt(OWNER, "user_ben", Some(AuthKind::ApiKey)).is_ok());
        assert!(r.may_prompt(OWNER, "user_zed", Some(AuthKind::ApiKey)).is_err());
        // A declared personal login wins over what the environment shows.
        r.auth = Some(AuthKind::Personal);
        assert!(r.may_prompt(OWNER, "user_ben", Some(AuthKind::ApiKey)).is_err());
        r.auth = Some(AuthKind::Team);
        assert!(r.may_prompt(OWNER, "user_ben", None).is_ok());
        assert!(r.may_prompt(OWNER, "chief:ben-chief", None).is_ok());
    }

    #[test]
    fn auth_is_detected_only_from_plain_signs() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
        };
        assert_eq!(AuthKind::detect(&env(&[])), None);
        assert_eq!(AuthKind::detect(&env(&[("ANTHROPIC_API_KEY", "sk-x")])), Some(AuthKind::ApiKey));
        assert_eq!(AuthKind::detect(&env(&[("CLAUDE_CODE_USE_BEDROCK", "1")])), Some(AuthKind::Bedrock));
        assert_eq!(AuthKind::detect(&env(&[("CLAUDE_CODE_USE_VERTEX", "0")])), None);
        assert_eq!(AuthKind::parse("api-key"), Some(AuthKind::ApiKey));
        assert_eq!(AuthKind::parse("max"), None);
    }

    #[test]
    fn patterns_parse_strictly() {
        for ok in ["Read", "Bash(git log*)", "Bash(make test)", "mcp__github__*", "Read(/a/*)", "WebFetch(https://docs.rs/*)"] {
            assert!(Pattern::parse(ok).is_ok(), "{ok}");
        }
        for bad in ["", "Bash(*)", "Read(relative/*)", "*", "mcp__*", "Foo(x)", "Bash(", "Bash()"] {
            assert!(Pattern::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn revoke_and_cli_round_trip() {
        let dir = std::env::temp_dir().join(format!("rights-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let w = |s: &str| s.split(' ').map(str::to_owned).collect::<Vec<_>>();
        run(&w("grant user_ben Read WebFetch"), &dir, OWNER).unwrap();
        run(&w("cap user_ben 2.5"), &dir, OWNER).unwrap();
        run(&w("chief-cap 20"), &dir, OWNER).unwrap();
        assert_eq!(run(&w("check user_ben Read"), &dir, OWNER).unwrap(), "allow (grant:Read)");
        run(&w("revoke user_ben Read"), &dir, OWNER).unwrap();
        assert!(run(&w("check user_ben Read"), &dir, OWNER).unwrap().starts_with("deny"));
        let r = Rights::load(&Rights::path(&dir)).unwrap();
        assert_eq!(r.people["user_ben"].allow, vec!["WebFetch".to_owned()]);
        assert_eq!(r.people["user_ben"].cap_usd_day, Some(2.5));
        assert_eq!(r.chief_cap_usd_day, Some(20.0));
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(Rights::path(&dir)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(run(&w("approver chief:x on"), &dir, OWNER).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_turn_hooks_run_first_and_turn_hooks_on() {
        let mut settings = json!({"disableAllHooks": true, "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": []}]}});
        add_turn_hooks(&mut settings, "/opt/o'c", Path::new("/h/tools.sock"));
        assert_eq!(settings["disableAllHooks"], json!(false));
        let pre = settings["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(pre.len(), 2);
        assert_eq!(pre[0]["matcher"], "*");
        assert_eq!(
            pre[0]["hooks"][0]["command"],
            "'/opt/o'\\''c' rights-hook pre --socket '/h/tools.sock'"
        );
        assert_eq!(settings["hooks"]["PostToolUse"][0]["hooks"][0]["command"].as_str().unwrap().contains("rights-hook post"), true);
    }

    #[test]
    fn a_hook_with_no_host_gives_no_decision() {
        let out = hook("pre", Path::new("/nonexistent/tools.sock"), &mut "{\"tool_name\":\"Bash\"}".as_bytes());
        assert_eq!(out, "");
    }

    #[test]
    fn a_table_that_does_not_parse_is_an_error() {
        let dir = std::env::temp_dir().join(format!("rights-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(FILE), r#"{"people":{"u":{"allow":["Bash(*)"]}}}"#).unwrap();
        assert!(Rights::load(&Rights::path(&dir)).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
