//! Each subagent's cmux workspace (Lawrence, 2026-10-05: "subagent
//! orchestration spawns workspaces that have the acp chat, so everything is
//! monitorable and I can jump in deeper using cmux ui"). A workspace named
//! after the subagent's task, whose selected tab is the agent chat of the
//! SAME acpmux session the Chief drives: the user watches its chat and tool
//! calls live and can write to it. It is named after its task's short title,
//! like any workspace (Leo 2026-10-21: no `aN · ` id in the sidebar; the id is
//! the Chief's own). It joins no sidebar group unless its task asks for the person's own
//! "Chief agents" group (`spawn_group`, #27712); no group is ever made. It stays after the subagent
//! finishes with its name untouched (Lawrence 2026-10-19: "I don't like the
//! checkmark"): the chat tab's own idle state shows it is done, and a name
//! the user gave it is never overwritten. Closing it only detaches the tab.
//!
//! The app opens it (`agent.openSessionWorkspace` through `action.run` on
//! its control socket, `CMUX_SOCKET_PATH`), with a workspace key chosen
//! here, so the host can rename the workspace later through the session
//! daemon (`rename-workspace` by key).

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

/// The app action that opens a session's chat in a new workspace.
pub const OPEN_ACTION: &str = "agent.openSessionWorkspace";
/// Characters of a workspace title.
const TITLE_CHARS: usize = 32;

/// Where subagents' workspaces are made.
pub trait Workspaces: Send + Sync {
    /// Opens workspace `key` (a fresh `new_key`, chosen before the session
    /// starts so the session can carry it as CMUX_WORKSPACE_ID) named `name`
    /// in the person's existing sidebar group `group` when that is
    /// ``AGENTS_GROUP_NAME`` (empty or any other name: ungrouped; no group is
    /// ever made; best effort),
    /// whose tab is acpmux session `session`'s chat; returns its key. The
    /// daemon place opens the chat tab only (no shell); the app place may
    /// still use `cwd`.
    fn open(
        &self,
        key: &str,
        session: &str,
        name: &str,
        group: &str,
        cwd: &Path,
    ) -> Result<String, String>;
    /// Renames the workspace `key`.
    fn rename(&self, key: &str, name: &str) -> Result<(), String>;
    /// Closes the workspace `key` (`OPTCHAT_SUBAGENT_ON_FINISH=close`): it
    /// goes to the closed history; the agent session stays.
    fn close(&self, _key: &str) -> Result<(), String> {
        Err("closing is not supported here".into())
    }
    /// Closes workspace `key` only when none of its terminals runs a command:
    /// Ok(true) closed, Ok(false) kept (a busy terminal). A short task's close.
    fn close_idle(&self, _key: &str) -> Result<bool, String> {
        Ok(false)
    }
    /// Where its workspaces live, for the Chief to tell the user (for
    /// example "the cmux app on this Mac").
    fn place(&self) -> String;
    /// The public id (`ws_…`) and session name of workspace `key`, so the
    /// Chief and the user can list, move and pin it with the cmux CLI
    /// (`cmux workspace <ws_…> move --index 0`); None when this place cannot
    /// name it.
    fn locate(&self, _key: &str) -> Option<WorkspaceRef> {
        None
    }
}

/// A subagent workspace as the cmux CLI and MCP address it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceRef {
    /// The workspace's public id (`ws_…`).
    pub id: String,
    /// The name of the cmux session that holds it (`cmux --session NAME`).
    pub session: String,
}

impl WorkspaceRef {
    /// The CLI command that moves this workspace to the top of its session. It names no
    /// `--session`: the workspace is in the session a cmux terminal and the Chief's turns
    /// already reach (the user's, or a server host's own), like any other (a423).
    pub fn move_to_top(&self) -> String {
        format!("cmux workspace {} move --index 0", self.id)
    }
}

/// The value of a leading `key: value` header line of `task` (`Title:`,
/// `Group:`), among its first three non-empty lines; any case.
pub fn header(task: &str, key: &str) -> Option<String> {
    task.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .take(3)
        .find_map(|line| {
            let (k, v) = line.split_once(':')?;
            (k.trim().eq_ignore_ascii_case(key) && !v.trim().is_empty())
                .then(|| v.trim().to_owned())
        })
}

/// Whether `line` is a `Title:` or `Group:` header.
fn is_header(line: &str) -> bool {
    line.split_once(':').is_some_and(|(k, _)| {
        let k = k.trim();
        k.eq_ignore_ascii_case("title") || k.eq_ignore_ascii_case("group")
    })
}

/// The first line of `task` that is not a header.
fn first_line(task: &str) -> &str {
    task.lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !is_header(l))
        .unwrap_or("")
}

/// A short title (at most 32 characters) for a task (Lawrence 2026-10-19:
/// "when you make a new workspace you do name it better"): its `Title:`
/// line, else its first line without the "User (u2455)," style preamble,
/// cut at its first clause. Never starts with "User".
pub fn title(task: &str) -> String {
    if let Some(t) = header(task, "title") {
        return clip(&t);
    }
    let mut s = first_line(task).to_owned();
    loop {
        let next = strip_preamble(&s);
        if next == s {
            break;
        }
        s = next;
    }
    let t = clip(&cut_clause(&s));
    if t.is_empty() || t.to_lowercase().starts_with("user") {
        return "Task".to_owned();
    }
    t
}

/// `s` without one leading preamble: "User (u2455):", "The user said
/// about X:", "cmux-next (repo …, branch …).", "Context:", quotes.
fn strip_preamble(s: &str) -> String {
    let s = s
        .trim()
        .trim_start_matches(['"', '\'', '“', '`', '-', '*', ' ']);
    let lower = s.to_lowercase();
    let preamble = ["the user", "user", "redo of", "follow-up to", "context"]
        .iter()
        .any(|p| {
            lower.starts_with(p)
                && lower[p.len()..]
                    .chars()
                    .next()
                    .is_none_or(|c| !c.is_alphanumeric())
        });
    if preamble {
        return after_mark(s, &[':', ',', '.']).to_owned();
    }
    for product in ["cmux-next", "cmux next"] {
        if lower.starts_with(product) {
            let rest = s[product.len()..].trim_start();
            if rest.starts_with('(') {
                return after_mark(rest, &[')'])
                    .trim_start_matches([',', '.', ':', ';'])
                    .trim()
                    .to_owned();
            }
            if let Some(r) = rest.strip_prefix(':').or_else(|| rest.strip_prefix(',')) {
                return r.trim().to_owned();
            }
            if rest.len() > 3 {
                return rest.to_owned();
            }
        }
    }
    s.to_owned()
}

/// What follows the first of `marks` outside parentheses; empty when none.
fn after_mark<'a>(s: &'a str, marks: &[char]) -> &'a str {
    let closing = marks.contains(&')');
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        if !closing {
            match c {
                '(' => depth += 1,
                ')' => depth -= 1,
                _ => {}
            }
        }
        if depth <= 0 && marks.contains(&c) {
            return s[i + c.len_utf8()..].trim();
        }
    }
    ""
}

/// The first clause of `s`: up to a sentence end, a colon, a quote, a
/// parenthesis or an embedded "User" preamble.
fn cut_clause(s: &str) -> String {
    let mut end = s.len();
    for mark in [
        ". ", ": ", "; ", " — ", " - ", "? ", "! ", " (", "\"", " User", " user (", " user:",
    ] {
        if let Some(i) = s.find(mark).filter(|&i| i > 0) {
            end = end.min(i);
        }
    }
    s[..end]
        .trim()
        .trim_end_matches(['.', ',', ':', ';', '"', '\''])
        .trim()
        .to_owned()
}

/// `s` on one line, at most ``TITLE_CHARS`` characters (cut at a word, with
/// "…"), its first letter upper case.
fn clip(s: &str) -> String {
    let flat = s
        .replace('✓', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let mut out = if flat.chars().count() <= TITLE_CHARS {
        flat
    } else {
        let head: String = flat.chars().take(TITLE_CHARS - 1).collect();
        // A whole word when the next character ends it.
        let whole = flat
            .chars()
            .nth(TITLE_CHARS - 1)
            .is_some_and(char::is_whitespace);
        let cut = if whole {
            head.len()
        } else {
            head.rfind(' ')
                .filter(|&i| i >= TITLE_CHARS / 2)
                .unwrap_or(head.len())
        };
        format!("{}…", head[..cut].trim_end_matches([',', ';', ':', ' ']))
    };
    if let Some(c) = out.chars().next()
        && c.is_lowercase()
        && !out.starts_with("cmux")
    {
        out = c.to_uppercase().collect::<String>() + &out[c.len_utf8()..];
    }
    out
}

/// The one sidebar group a subagent workspace may join (#27712): the person's own
/// "Chief agents" group, when the sidebar has it. The host never makes a group and never picks
/// one by topic or by a name close to the task's.
pub const AGENTS_GROUP_NAME: &str = "Chief agents";

/// The group a spawn task asks for: ``AGENTS_GROUP_NAME`` when its `Group:` line names it (any
/// case; a line that runs on after a full stop, "Chief agents. Repo ~/fun/…", still does), else
/// empty (ungrouped). Any other `Group:` value is ignored.
pub fn spawn_group(task: &str) -> &'static str {
    let Some(group) = header(task, "group") else {
        return "";
    };
    let named = group
        .split(". ")
        .next()
        .unwrap_or("")
        .trim()
        .trim_end_matches('.');
    if named.trim().eq_ignore_ascii_case(AGENTS_GROUP_NAME) {
        AGENTS_GROUP_NAME
    } else {
        ""
    }
}

/// `key` as CMUX_WORKSPACE_ID: the uppercase UUID form a cmux terminal
/// carries (the app's `DaemonConnection.uuidForm`).
pub fn env_id(key: &str) -> String {
    key.to_uppercase()
}

/// A fresh workspace key in the daemon's canonical form (a lowercase UUID v4).
pub fn new_key() -> String {
    let mut bytes = [0u8; 16];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// The app's control socket and the session daemon.
pub struct AppWorkspaces {
    pub control: PathBuf,
    pub daemon: PathBuf,
    /// The Chief home (`MUX_HOME`), whose own acpmux runs the subagents: the
    /// tab's host is `chief:<home id>`, so the app attaches it there.
    pub home: Option<PathBuf>,
}

impl AppWorkspaces {
    /// From the host's env: `CMUX_SOCKET_PATH` (None without it) and the
    /// app's daemon, where the app makes the workspaces.
    pub fn from_env(daemon: &str) -> Option<AppWorkspaces> {
        AppWorkspaces::resolve(daemon, &crate::cli::env)
    }

    /// `CMUX_SOCKET_PATH` from `env`, and the daemon that holds the app's
    /// workspaces: `CMUX_APP_DAEMON_SOCKET` when the app sets it (the host's
    /// `--daemon-socket` is then the Chief's conversation owner), else
    /// `daemon` (cmux_env::app_daemon_socket).
    pub fn resolve(daemon: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<AppWorkspaces> {
        env("CMUX_SOCKET_PATH").map(|control| AppWorkspaces {
            control: control.into(),
            daemon: crate::cmux_env::app_daemon_socket(daemon, env).into(),
            home: None,
        })
    }

    /// The same, for the Chief home `home`.
    pub fn with_home(mut self, home: &Path) -> AppWorkspaces {
        self.home = Some(home.to_owned());
        self
    }
}

/// The session daemon where subagent workspaces are made, None when this host has no cmux
/// app (then a cloud install's own daemon holds them). `owner` is the host's `--daemon-socket`.
///
/// With the app it is the app's own daemon (`CMUX_APP_DAEMON_SOCKET`, the link the app keeps
/// at `state/app-daemon.sock`): the session that holds the user's own workspaces (a423,
/// Lawrence 2026-10-21: "all workspaces must be the same"). A subagent's workspace is then an
/// ordinary workspace there, made with the same daemon ops, ungrouped unless it asked for "Chief agents", and owned by
/// that daemon like any other; only its chat tab names the Chief home's acpmux as its host.
/// It used to be the Chief's owner daemon (`cmux-chief-<id>`, hq-6d 2026-10-09), which the
/// app showed apart under a "Chief" header.
pub fn subagent_daemon(owner: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    AppWorkspaces::resolve(owner, env).map(|app| app.daemon)
}

/// Where a Chief host makes its subagents' workspaces (`placement`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Placement {
    /// The cmux app that started this host: its own daemon (the user's session).
    App(PathBuf),
    /// A cloud install's own daemon (`install:<id>` host).
    Cloud(PathBuf, String),
    /// No app and no install (an always-on local brain, a teammate's Chief started by
    /// the CLI or a service): this host's own session daemon, so any app connected
    /// to this machine's session shows them.
    OwnDaemon(PathBuf),
    /// Turned off with `OPTCHAT_SUBAGENT_WORKSPACES=0`.
    Off,
}

/// Where subagent workspaces go. A fresh Chief on a machine without `CMUX_SOCKET_PATH`
/// used to get none (every spawn answered "no cmux workspace"): it now falls back to the
/// host's own session daemon, as the cloud install does.
pub fn placement(
    off: bool,
    owner: &str,
    env: &dyn Fn(&str) -> Option<String>,
    cloud_install: Option<&str>,
) -> Placement {
    if off {
        return Placement::Off;
    }
    if let Some(app) = subagent_daemon(owner, env) {
        return Placement::App(app);
    }
    match cloud_install {
        Some(install) => Placement::Cloud(owner.into(), install.to_owned()),
        None => Placement::OwnDaemon(owner.into()),
    }
}

/// The Markdown link that names subagent `id` (`[a1](cmux://chief/<home id>/session/<session>)`):
/// the app's deeplink of its session in the Chief home whose `mux.parent` tag is `parent`
/// (`optchat-chief:<home id>`). The app opens the tab that shows that session (host
/// `chief:<home id>`); Home allows the form only for this Chief's own subagents. None when the
/// tag names no home or the session id needs escaping.
pub fn subagent_link(parent: &str, id: &str, session: &str) -> Option<String> {
    let home = parent.strip_prefix("optchat-chief:")?;
    let token = |t: &str| {
        !t.is_empty()
            && t.len() <= 200
            && t.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
    };
    (home.len() == 8
        && home
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        && token(session))
    .then(|| format!("[{id}](cmux://chief/{home}/session/{session})"))
}

/// `text` with each mention of a known subagent (`a1`, or `[a1]` not already a link) written as
/// its link (`subagent_link`), so every client shows it as a link whether or not the model
/// wrote one (Lawrence 2026-10-10). `session_of` names a subagent's session (None: not one of
/// this Chief's, left as written). Code spans and fences, existing links and words inside a
/// longer token (`ma1`, `a1b`, `/a1`, `a1.txt`) are left alone.
pub fn link_subagents(
    text: &str,
    parent: &str,
    session_of: impl Fn(&str) -> Option<String>,
) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let (mut i, mut copied) = (0, 0);
    let mut fence = false;
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    let link_of = |id: &str| session_of(id).and_then(|s| subagent_link(parent, id, &s));
    while i < b.len() {
        let line_start = i == 0 || b[i - 1] == b'\n';
        if line_start && text[i..].starts_with("```") {
            fence = !fence;
            i += 3;
            continue;
        }
        if fence {
            i += 1;
            continue;
        }
        match b[i] {
            b'`' => {
                // An inline code span: to its closing backtick on this line.
                let end = text[i + 1..]
                    .find(['`', '\n'])
                    .map_or(b.len(), |e| i + 1 + e);
                i = if end < b.len() && b[end] == b'`' {
                    end + 1
                } else {
                    i + 1
                };
            }
            b'[' => {
                let close = text[i + 1..].find([']', '\n']).map(|e| i + 1 + e);
                match close {
                    Some(c) if b[c] == b']' && b.get(c + 1) == Some(&b'(') => {
                        // An existing link: skip it whole.
                        i = text[c..].find(')').map_or(c + 1, |e| c + e + 1);
                    }
                    Some(c) if b[c] == b']' => {
                        let id = &text[i + 1..c];
                        if is_id(id)
                            && let Some(link) = link_of(id)
                        {
                            out.push_str(&text[copied..i]);
                            out.push_str(&link);
                            copied = c + 1;
                        }
                        i = c + 1;
                    }
                    _ => i += 1,
                }
            }
            b'a' if i == 0
                || emphasis_before(b, i)
                || !(word(b[i - 1])
                    || matches!(b[i - 1], b'/' | b'.' | b'-' | b':' | b'#' | b'@')) =>
            {
                let end = i + 1 + b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
                let id = &text[i..end];
                let bounded = end > i + 1
                    && (emphasis_after(b, end)
                        || !(end < b.len()
                            && (word(b[end])
                                || (b[end] == b'.' && b.get(end + 1).is_some_and(|c| word(*c))))));
                if bounded
                    && is_id(id)
                    && let Some(link) = link_of(id)
                {
                    out.push_str(&text[copied..i]);
                    out.push_str(&link);
                    copied = end;
                }
                i = end;
            }
            _ => i += 1,
        }
    }
    out.push_str(&text[copied..]);
    out
}

/// Whether `b[..i]` ends with a `_`/`__` emphasis opener (`_a1_`, `__a1__`), not snake_case
/// (`foo_a1`): the underscores follow the start, a space or punctuation.
fn emphasis_before(b: &[u8], i: usize) -> bool {
    let run = b[..i].iter().rev().take_while(|c| **c == b'_').count();
    (1..=3).contains(&run) && (run == i || !b[i - run - 1].is_ascii_alphanumeric())
}

/// Whether `b[end..]` starts with a `_`/`__` emphasis closer (`_a1_`), not snake_case (`a1_x`).
fn emphasis_after(b: &[u8], end: usize) -> bool {
    let run = b[end..].iter().take_while(|c| **c == b'_').count();
    (1..=3).contains(&run) && b.get(end + run).is_none_or(|c| !c.is_ascii_alphanumeric())
}

/// A subagent id: `a` and 1 to 6 digits, no leading zero.
fn is_id(id: &str) -> bool {
    let digits = id.strip_prefix('a').unwrap_or("");
    (1..=6).contains(&digits.len())
        && !digits.starts_with('0')
        && digits.bytes().all(|c| c.is_ascii_digit())
}

/// The agent tab host of a session in Chief home `home`'s acpmux.
pub fn chief_host(home: &Path) -> String {
    format!("chief:{}", crate::paths::home_id(home))
}

/// `open_request` whose tab names Chief home `home` as its session's host.
pub fn open_request_for(home: &Path, session: &str, name: &str, key: &str, cwd: &Path) -> Value {
    let mut request = open_request(session, name, key, cwd);
    request["params"]["args"]["host"] = json!(chief_host(home));
    request
}

/// The `action.run` request that opens `session` in workspace `key`.
pub fn open_request(session: &str, name: &str, key: &str, cwd: &Path) -> Value {
    json!({
        "id": 1,
        "method": "action.run",
        "params": {
            "action": OPEN_ACTION,
            "args": {"session": session, "name": name, "key": key, "cwd": cwd.display().to_string()},
            "wait": true,
            // A script's run: it never takes focus or switches workspaces.
            "origin": "script",
            "idempotency_key": format!("optchat-subagent-workspace-{key}"),
        }
    })
}

/// One request on the app's control socket; Ok carries its result.
pub fn control_call(socket: &Path, request: &Value, timeout: Duration) -> Result<Value, String> {
    let (value, answer) = control_reply(socket, request, timeout)?;
    reply_result(&value, &answer)
}

/// The app's reply `value` (its line `answer`): Ok with its result, else its error message.
pub fn reply_result(value: &Value, answer: &str) -> Result<Value, String> {
    match value.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(value.get("result").cloned().unwrap_or(Value::Null)),
        _ => Err(value
            .get("error")
            .map(|e| {
                e.get("message")
                    .and_then(Value::as_str)
                    .map_or_else(|| e.to_string(), str::to_owned)
            })
            .unwrap_or_else(|| answer.to_owned())),
    }
}

/// One request on the app's control socket and its reply line, parsed, whatever it says;
/// Err only when the app did not answer (no socket, a closed one, a timeout, no JSON).
pub fn control_reply(
    socket: &Path,
    request: &Value,
    timeout: Duration,
) -> Result<(Value, String), String> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|e| format!("the app's control socket {}: {e}", socket.display()))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| e.to_string())?;
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    let mut answer = String::new();
    BufReader::new(stream)
        .read_line(&mut answer)
        .map_err(|e| format!("reading the app's answer: {e}"))?;
    let answer = answer.trim();
    if !answer.starts_with('{') {
        return Err(if answer.is_empty() {
            "the app closed the control socket".to_owned()
        } else {
            answer.to_owned()
        });
    }
    let value: Value = serde_json::from_str(answer).map_err(|e| format!("bad answer: {e}"))?;
    Ok((value, answer.to_owned()))
}

impl Workspaces for AppWorkspaces {
    /// The app makes the workspace; the host then moves it into `group`
    /// on the app's session daemon, by key.
    fn open(
        &self,
        key: &str,
        session: &str,
        name: &str,
        group: &str,
        cwd: &Path,
    ) -> Result<String, String> {
        let key = key.to_owned();
        let opened = match control_call(
            &self.control,
            &match &self.home {
                Some(home) => open_request_for(home, session, name, &key, cwd),
                None => open_request(session, name, &key, cwd),
            },
            Duration::from_secs(60),
        ) {
            Ok(_) => Ok(key),
            // The action declares that it starts a terminal, so the app
            // waits the terminal start deadline and answers once the
            // workspace exists; past even that, its work goes on and the
            // workspace still comes under the key chosen here (a done
            // rename before then fails and is logged).
            Err(e) if still_running(&e) => Ok(key),
            Err(e) => Err(e),
        }?;
        // Best effort: a sidebar group never fails the subagent's start.
        if let Err(e) = group_by_key(&self.daemon, &opened, group) {
            eprintln!("optchat: subagent workspace {opened} stays ungrouped: {e}");
        }
        Ok(opened)
    }

    fn close(&self, key: &str) -> Result<(), String> {
        close_by_key(&self.daemon, key)
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        rename_by_key(&self.daemon, key, name)
    }

    fn place(&self) -> String {
        "the cmux app on this Mac".to_owned()
    }
}

/// The daemon capability of workspace groups.
const GROUPS: &str = "workspace-groups-v1";

/// Puts `workspace` in the session's existing ``AGENTS_GROUP_NAME`` group when `name` asks for
/// it (``agents_group``); any other name, or no such group, leaves it ungrouped. Never makes a
/// group. Only a failed move is an error.
/// `workspace` None moves it by its key (a workspace the app made).
fn group_workspace(
    client: &mut cmux::raw::Client,
    workspace: Option<u64>,
    key: &str,
    name: &str,
) -> Result<(), String> {
    use cmux::raw::{ListWorkspaceGroupsRequest, MoveWorkspaceToGroupRequest, Optional};
    if name.is_empty() {
        return Ok(());
    }
    let listed = client
        .list_workspace_groups(ListWorkspaceGroupsRequest {})
        .ok()
        .map(|listed| groups_of(&listed["groups"]))
        .unwrap_or_default();
    let Some(group) = agents_group(name, &listed) else {
        return Ok(());
    };
    client
        .move_workspace_to_group(MoveWorkspaceToGroupRequest {
            workspace: workspace.map_or(Optional::Missing, Optional::Value),
            key: match workspace {
                Some(_) => Optional::Missing,
                None => Optional::Value(key.to_owned()),
            },
            group: Optional::Value(group),
            mutation_id: Optional::Value(format!("optchat-subagent-group-{key}")),
            origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
            ..Default::default()
        })
        .map(|_| ())
        .map_err(|e| format!("move-workspace-to-group: {e}"))
}

/// One `cmux.protocol/2` request (a resource operation, as the `cmux` CLI sends it) on the
/// session daemon at `daemon`; Ok carries its result. A mutation carries `idempotency_key`.
pub fn resource_call(
    daemon: &Path,
    operation: &str,
    params: Value,
    idempotency_key: Option<&str>,
) -> Result<Value, String> {
    let mut stream = UnixStream::connect(daemon).map_err(|e| format!("the session daemon: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(|e| e.to_string())?;
    let id = format!("optchat-{}", new_key());
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": operation,
        "params": params,
    });
    if let Some(key) = idempotency_key {
        request["idempotency_key"] = json!(key);
    }
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    for answer in BufReader::new(stream).lines() {
        let answer = answer.map_err(|e| format!("reading the daemon's answer: {e}"))?;
        let Ok(value) = serde_json::from_str::<Value>(&answer) else {
            continue;
        };
        if value["id"] != json!(id) {
            continue;
        }
        return match value["ok"].as_bool() {
            Some(true) => Ok(value["result"].clone()),
            _ => Err(value["error"]["message"]
                .as_str()
                .map_or_else(|| value["error"].to_string(), str::to_owned)),
        };
    }
    Err("the session daemon closed the connection".to_owned())
}

/// The user's home directory from the environment (`HOME`), empty when unset.
fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// The index a workspace takes in the personal group it joins, from the same
/// `workspaces.newPlacement` the app reads (cmux-next.json, else cmux.json; see
/// `agent_memory::settings`). `top`, the default, puts it first (index 0); `bottom` and
/// `afterCurrent` keep the daemon's place, the end. None keeps the daemon default.
pub fn new_group_index(home: &Path) -> Option<usize> {
    let placement = crate::agent_memory::settings::document(home).and_then(|doc| {
        doc.pointer("/workspaces/newPlacement")
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    match placement.as_deref() {
        Some("bottom" | "afterCurrent") => None,
        // No file, no key, or a value the app does not know: the app's default, `top`.
        _ => Some(0),
    }
}

/// Puts workspace `key` of the user's session (the app's daemon at `daemon`) in that
/// session's existing personal ``AGENTS_GROUP_NAME`` group when `name` asks for it
/// (``agents_group``): the `workspace_group.list` and `workspace.place` operations `cmux
/// workspace group <g> add` sends, so it sits in the group exactly as a workspace the user
/// grouped does (a423). Any other name, or no such group, leaves it ungrouped; no group is made
/// (#27712).
pub fn place_in_personal_group(daemon: &Path, key: &str, name: &str) -> Result<(), String> {
    place_in_personal_group_from(daemon, key, name, &home_dir())
}

/// [`place_in_personal_group`] with `workspaces.newPlacement` read from home folder `home`: under
/// `top` (the default) the workspace goes first in its group, else last.
pub fn place_in_personal_group_from(
    daemon: &Path,
    key: &str,
    name: &str,
    home: &Path,
) -> Result<(), String> {
    if name.is_empty() {
        return Ok(());
    }
    let here = || json!({"machine": "current", "session": "current"});
    let listed = resource_call(daemon, "workspace_group.list", here(), None)?;
    let Some(group) = agents_group(name, &groups_of(&listed)) else {
        return Ok(());
    };
    let workspace = locate_by_key(daemon, key)
        .ok_or("the session does not list the new workspace")?
        .id;
    let mut params = here();
    params["workspace"] = json!(workspace);
    params["group"] = json!(group);
    // Lawrence 2026-10-28: a new workspace made in a group goes to the top of that group under
    // `top` (the default), as Cmd-N in a group does; without an index the daemon put it last.
    if let Some(index) = new_group_index(home) {
        params["index"] = json!(index);
    }
    resource_call(
        daemon,
        "workspace.place",
        params,
        Some(&format!("optchat-subagent-place-{key}")),
    )
    .map(|_| ())
}

/// Puts the workspace `key` on the session daemon at `daemon` in the group
/// named `name`, when the daemon has workspace groups.
fn group_by_key(daemon: &Path, key: &str, name: &str) -> Result<(), String> {
    use cmux::raw::{Client, ClientConfig};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon))
        .map_err(|e| format!("the session daemon: {e}"))?;
    let groups = client
        .identify_server()
        .map(|info| info.capabilities.unwrap_or_default())
        .is_ok_and(|caps| caps.iter().any(|c| c == GROUPS));
    let result = if groups {
        group_workspace(&mut client, None, key, name)
    } else {
        Ok(())
    };
    client.close();
    result
}

/// A host without a cmux app (an always-on brain on a server): each
/// subagent's workspace is made in this host's OWN session daemon. The
/// subagent runs on this machine, so its workspace belongs to this machine's
/// session (data-model.md 1.2); every cmux app connected to that session
/// shows it, also while the user's laptop sleeps. An app on another machine
/// shows the chat tab as running on `host_name` until it can attach to this
/// host's acpmux.
pub struct DaemonWorkspaces {
    /// This host's session daemon.
    pub daemon: PathBuf,
    /// `install:<id>` of this machine: the install whose acpmux runs the session.
    pub host: String,
    /// This machine's display name.
    pub host_name: String,
    /// The subagent harness, shown on the tab.
    pub harness: Option<String>,
    /// Whether `daemon` is the app's own daemon, the user's session: its sidebar groups and
    /// order are the personal ones (`workspace_group.*`, `workspace.place`, what `cmux
    /// workspace group <g> add` sends), not the daemon's older shared groups, which the app
    /// does not show for that session (a423).
    pub personal: bool,
    /// The daemon to use while nothing listens at `daemon`: the host's own session daemon,
    /// for an app link (`state/app-daemon.sock`) that dangles because no cmux app opened
    /// this Chief home (a scratch Chief the `cmux chief` CLI started). None: `daemon` only.
    pub fallback: Option<PathBuf>,
}

impl DaemonWorkspaces {
    /// The daemon to use now and whether it is the user's session (personal groups):
    /// `daemon` while something listens there, else `fallback` (the host's own session).
    /// Checked per call: an app that opens Home later points the link at its daemon.
    fn target(&self) -> (&Path, bool) {
        match &self.fallback {
            Some(own) if std::os::unix::net::UnixStream::connect(&self.daemon).is_err() => {
                (own.as_path(), false)
            }
            _ => (self.daemon.as_path(), self.personal),
        }
    }

    fn client(&self, daemon: &Path) -> Result<cmux::raw::Client, String> {
        use cmux::raw::{Client, ClientConfig};
        Client::connect(ClientConfig::from_socket_path(daemon))
            .map_err(|e| format!("the session daemon: {e}"))
    }

    /// The daemons that may hold workspace `key`: `daemon`, then `fallback`.
    fn holders(&self) -> impl Iterator<Item = &Path> {
        std::iter::once(self.daemon.as_path()).chain(self.fallback.as_deref())
    }
}

impl Workspaces for DaemonWorkspaces {
    fn open(
        &self,
        key: &str,
        session: &str,
        name: &str,
        group: &str,
        cwd: &Path,
    ) -> Result<String, String> {
        use cmux::raw::{
            AgentSessionSource, CreateWorkspaceRequest, NewConversationTabRequest, Optional,
        };
        const TABS: &str = "agent-session-tabs-v1";
        let (daemon, personal) = self.target();
        let mut client = self.client(daemon)?;
        // Refused before any write: a workspace without its chat tab helps no one.
        let capabilities = client
            .identify_server()
            .map(|info| info.capabilities.unwrap_or_default());
        let groups = capabilities
            .as_ref()
            .is_ok_and(|caps| caps.iter().any(|c| c == GROUPS));
        let supported = capabilities.map(|caps| caps.iter().any(|c| c == TABS));
        match supported {
            Ok(true) => {}
            Ok(false) => {
                client.close();
                return Err(format!("this host's session daemon has no {TABS}"));
            }
            Err(e) => {
                client.close();
                return Err(format!("identify: {e}"));
            }
        }
        let key = key.to_owned();
        let result = (|| {
            let workspace = client
                .create_workspace(CreateWorkspaceRequest {
                    key: Optional::Value(key.clone()),
                    name: Optional::Value(name.to_owned()),
                    mutation_id: Optional::Value(format!("optchat-subagent-ws-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("create-workspace: {e}"))?
                .workspace;
            // Best effort: a sidebar group never fails the subagent's start.
            let grouped = if personal {
                place_in_personal_group(daemon, &key, group)
            } else if groups {
                group_workspace(&mut client, Some(workspace), &key, group)
            } else {
                Ok(())
            };
            if let Err(e) = grouped {
                eprintln!("optchat: subagent workspace {key} stays ungrouped: {e}");
            }
            // The chat tab only, in the workspace's first pane: no shell (Lawrence
            // 2026-10-21). Every subagent's idle shell held a terminal host and a PTY
            // until its workspace closed; 369 of them filled the Mac's 511 PTYs. The
            // user opens a shell in the workspace when they want one.
            let _ = cwd;
            client
                .new_conversation_tab(NewConversationTabRequest {
                    workspace: Optional::Value(workspace),
                    agent_session: Optional::Value(AgentSessionSource {
                        host: self.host.clone(),
                        host_name: Optional::Value(self.host_name.clone()),
                        session: Optional::Value(session.to_owned()),
                        harness: self
                            .harness
                            .clone()
                            .map_or(Optional::Missing, Optional::Value),
                    }),
                    mutation_id: Optional::Value(format!("optchat-subagent-tab-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("new-conversation-tab: {e}"))?;
            Ok::<(), String>(())
        })();
        client.close();
        // A workspace made before a later step failed (new-conversation-tab refused, or
        // earlier create-terminal's "failed to spawn PTY command", a622-a627) is closed,
        // not left as an empty row with no chat.
        if let Err(e) = &result
            && !e.starts_with("create-workspace")
            && let Err(close) = close_by_key(daemon, &key)
        {
            eprintln!("optchat: subagent workspace {key} stays after {e}: {close}");
        }
        result.map(|()| key)
    }

    fn close_idle(&self, key: &str) -> Result<bool, String> {
        for daemon in self.holders() {
            let Ok(tree) = LineClient::connect(daemon).and_then(|mut c| c.workspaces()) else {
                continue;
            };
            let Some(ws) = tree["workspaces"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|w| w["key"].as_str() == Some(key))
            else {
                continue;
            };
            if busy_terminal(ws).is_some() {
                return Ok(false);
            }
            return close_by_key(daemon, key).map(|()| true);
        }
        Err(format!("no session daemon lists workspace {key}"))
    }

    fn close(&self, key: &str) -> Result<(), String> {
        let mut first = None;
        for daemon in self.holders() {
            match close_by_key(daemon, key) {
                Ok(()) => return Ok(()),
                Err(e) => first = first.or(Some(e)),
            }
        }
        Err(first.unwrap_or_default())
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        let mut first = None;
        for daemon in self.holders() {
            match rename_by_key(daemon, key, name) {
                Ok(()) => return Ok(()),
                Err(e) => first = first.or(Some(e)),
            }
        }
        Err(first.unwrap_or_default())
    }

    fn locate(&self, key: &str) -> Option<WorkspaceRef> {
        self.holders().find_map(|daemon| locate_by_key(daemon, key))
    }

    fn place(&self) -> String {
        // The app's daemon (tabs on `chief:<home id>`, the Chief home's acpmux): the user's
        // own session, beside the workspaces the user made (a423).
        if self.host.starts_with("chief:") && self.target().1 {
            return "your cmux session on this Mac, beside your own workspaces".to_owned();
        }
        format!(
            "the cmux session on {0} (a cmux app shows it only while connected to {0})",
            self.host_name
        )
    }
}

/// This machine's short name (`hostname -s`), for the tabs other apps show.
pub fn host_name() -> String {
    std::process::Command::new("/bin/hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "this machine".into())
}

/// The app's answer to a waiting run whose work goes on past its deadline.
pub fn still_running(error: &str) -> bool {
    error.contains("did not finish within")
}

/// The origin of this host's workspace mutations: the session daemon needs one with every
/// mutation_id (server.rs workspace_mutation), so a retried create replays instead of doubling.
const MUTATION_ORIGIN: &str = "optchat-chief";

/// The public id and session name of workspace `key` on the session daemon at
/// `daemon`: `list-workspaces` carries each workspace's key beside its
/// `resource_id` (tree_json.rs), and `identify` names the session.
fn locate_by_key(daemon: &Path, key: &str) -> Option<WorkspaceRef> {
    use cmux::raw::{Client, ClientConfig};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon)).ok()?;
    let session = client.identify_server().ok().map(|info| info.session);
    let mut request = serde_json::Map::new();
    request.insert("cmd".into(), json!("list-workspaces"));
    let tree = client.request_raw(request).ok();
    client.close();
    let id = tree?["data"]["workspaces"]
        .as_array()?
        .iter()
        .find(|w| w["key"].as_str() == Some(key))?["resource_id"]
        .as_str()
        .filter(|id| id.starts_with("ws_"))?
        .to_owned();
    let session = session.filter(|s| !s.is_empty())?;
    Some(WorkspaceRef { id, session })
}

/// `rename-workspace` by key on the session daemon at `daemon`.
/// Closes workspace `key` and ends any terminal the user opened there; the
/// agent session is acpmux's and stays.
fn close_by_key(daemon: &Path, key: &str) -> Result<(), String> {
    use cmux::raw::{Client, ClientConfig, CloseWorkspaceRequest, Optional};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon))
        .map_err(|e| format!("the session daemon: {e}"))?;
    let result = client
        .close_workspace(CloseWorkspaceRequest {
            end_terminals: Some(true),
            expected_generation: Optional::Missing,
            expected_revision: Optional::Missing,
            if_empty: None,
            key: Optional::Value(key.to_owned()),
            mutation_id: Optional::Value(format!("optchat-subagent-close-{key}")),
            origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
            reason: Optional::Missing,
            report_closed_ids: None,
            workspace: Optional::Missing,
        })
        .map(|_| ())
        .map_err(|e| format!("close-workspace: {e}"));
    client.close();
    result
}

fn rename_by_key(daemon: &Path, key: &str, name: &str) -> Result<(), String> {
    use cmux::raw::{Client, ClientConfig, Optional, RenameWorkspaceRequest};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon))
        .map_err(|e| format!("the session daemon: {e}"))?;
    let result = client
        .rename_workspace(RenameWorkspaceRequest {
            expected_generation: Optional::Missing,
            expected_name_revision: Optional::Missing,
            expected_revision: Optional::Missing,
            key: Optional::Value(key.to_owned()),
            mutation_id: Optional::Missing,
            name: name.to_owned(),
            origin: Optional::Missing,
            release: None,
            source: Optional::Missing,
            workspace: Optional::Missing,
        })
        .map(|_| ())
        .map_err(|e| format!("rename-workspace: {e}"));
    client.close();
    result
}

/// The capabilities a reader of conversation tabs declares, so the daemon lists a chat tab as
/// itself (`conversation.agent_session`), not as the blank page it downgrades to.
const TAB_CAPABILITIES: [&str; 4] = [
    "conversation-tabs-v1",
    "agent-session-tabs-v1",
    "page-tabs-v1",
    "frontend-browser-tabs-v1",
];

/// One JSON-line connection to a session daemon that reads conversation tabs canonically.
struct LineClient {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl LineClient {
    fn connect(socket: &Path) -> Result<LineClient, String> {
        let stream = UnixStream::connect(socket)
            .map_err(|e| format!("the session daemon {}: {e}", socket.display()))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(60)))
            .map_err(|e| e.to_string())?;
        let writer = stream.try_clone().map_err(|e| e.to_string())?;
        let mut client = LineClient {
            reader: BufReader::new(stream),
            writer,
            next: 0,
        };
        client.call(json!({"cmd": "set-client-info", "kind": "automation",
            "name": "optchat-chief", "capabilities": TAB_CAPABILITIES}))?;
        Ok(client)
    }

    /// One request; Ok carries its `data`.
    fn call(&mut self, mut request: Value) -> Result<Value, String> {
        self.next += 1;
        request["id"] = json!(self.next);
        let what = request["cmd"].as_str().unwrap_or("request").to_owned();
        let mut line = request.to_string().into_bytes();
        line.push(b'\n');
        self.writer.write_all(&line).map_err(|e| e.to_string())?;
        loop {
            let mut answer = String::new();
            if self
                .reader
                .read_line(&mut answer)
                .map_err(|e| e.to_string())?
                == 0
            {
                return Err(format!("{what}: the session daemon closed the connection"));
            }
            let Ok(value) = serde_json::from_str::<Value>(&answer) else {
                continue;
            };
            if value["id"] != json!(self.next) {
                continue;
            }
            return match value["ok"].as_bool() {
                Some(true) => Ok(value["data"].clone()),
                _ => Err(format!(
                    "{what}: {}",
                    value["error"]["message"]
                        .as_str()
                        .map_or_else(|| value["error"].to_string(), str::to_owned)
                )),
            };
        }
    }

    fn workspaces(&mut self) -> Result<Value, String> {
        self.call(json!({"cmd": "list-workspaces"}))
    }
}

/// Every tab of tree workspace `ws`, pane by pane.
fn tree_tabs(ws: &Value) -> Vec<Value> {
    let mut tabs = Vec::new();
    for screen in ws["screens"].as_array().into_iter().flatten() {
        for pane in screen["panes"].as_array().into_iter().flatten() {
            tabs.extend(pane["tabs"].as_array().into_iter().flatten().cloned());
        }
    }
    tabs
}

/// What a live terminal of `ws` runs, when it is not an idle shell (an idle shell titles
/// itself `user@host:dir`): such a workspace stays where it is until its command ends.
fn busy_terminal(ws: &Value) -> Option<String> {
    tree_tabs(ws).into_iter().find_map(|t| {
        let live = t["kind"] == "pty" && t["dead"] != json!(true);
        let title = t["title"].as_str().unwrap_or("").to_owned();
        let idle = title
            .split_once(':')
            .is_some_and(|(who, _)| who.contains('@'));
        (live && !idle).then_some(if title.is_empty() {
            "a terminal".to_owned()
        } else {
            title
        })
    })
}

/// `name` without the `aN · ` the Chief once put before every subagent workspace's name (the
/// app hid it in the Chief's own section, so this is the name the user saw).
fn shown_name(name: &str) -> String {
    let rest = name.strip_prefix('a').and_then(|r| {
        let digits = r.bytes().take_while(u8::is_ascii_digit).count();
        (1..=6).contains(&digits).then(|| &r[digits..])
    });
    match rest.and_then(|r| r.strip_prefix(" · ")) {
        Some(task) if !task.trim().is_empty() => task.to_owned(),
        _ => name.to_owned(),
    }
}

/// Moves every workspace on the Chief's owner daemon `owner` into the user's session, the
/// app's daemon `app` (a423, Lawrence 2026-10-21: "all workspaces must be the same"); answers
/// how many moved. Each becomes an ordinary workspace there with the same key (a running
/// subagent's CMUX_WORKSPACE_ID still names it), the name the user saw, its tabs (each agent
/// chat on the same acpmux session and each page; never an idle shell: a terminal tab is not
/// re-created, Lawrence 2026-10-21) and the person's existing "Chief agents" group when it was in one of that name (no group is made). The old one closes (to the owner's
/// closed history) only after every chat tab is in the new one; a copy that could not take
/// every chat is closed instead, for the next start to try again. A workspace whose terminal
/// runs a command stays. One that the user's session already holds by key is not copied twice.
///
/// - Returns: the number of workspaces moved.
/// - Throws: when either daemon cannot be read.
pub fn adopt_owner_workspaces(owner: &Path, app: &Path) -> Result<usize, String> {
    let mut from = LineClient::connect(owner)?;
    let mut to = LineClient::connect(app)?;
    let tree = from.workspaces()?;
    let group_names: std::collections::HashMap<String, String> = tree["groups"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|g| Some((g["id"].as_str()?.to_owned(), g["name"].as_str()?.to_owned())))
        .collect();
    let held: std::collections::HashSet<String> = to.workspaces()?["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| w["key"].as_str().map(str::to_owned))
        .collect();
    let mut moved = 0;
    // Bottom first: the user's session lists each new workspace first, so the order holds.
    let workspaces: Vec<Value> = tree["workspaces"].as_array().cloned().unwrap_or_default();
    for ws in workspaces.iter().rev() {
        let Some(key) = ws["key"].as_str() else {
            continue;
        };
        if ws["kind"] != "normal" {
            continue;
        }
        if let Some(command) = busy_terminal(ws) {
            eprintln!(
                "optchat: workspace {key} stays on the Chief's session while it runs {command}"
            );
            continue;
        }
        // Only a chat makes a subagent workspace worth moving: without one, the copy
        // would be an empty workspace (its idle shell is never re-created).
        if !tree_tabs(ws)
            .iter()
            .any(|tab| tab["conversation"].is_object())
        {
            eprintln!("optchat: workspace {key} has no chat; it stays on the Chief's session");
            continue;
        }
        let group = ws["group"]
            .as_str()
            .and_then(|g| group_names.get(g))
            .cloned()
            .unwrap_or_default();
        if held.contains(key) {
            eprintln!(
                "optchat: workspace {key} is already in the user's session; left on the Chief's"
            );
            continue;
        }
        match copy_workspace(&mut to, app, ws, key, &group) {
            Ok(()) => {
                let closed = from.call(json!({"cmd": "close-workspace", "key": key,
                    "end_terminals": true, "mutation_id": format!("optchat-adopt-close-{key}"),
                    "origin": MUTATION_ORIGIN}));
                match closed {
                    Ok(_) => moved += 1,
                    Err(e) => {
                        eprintln!("optchat: workspace {key} moved, but its old copy stays: {e}")
                    }
                }
            }
            Err(e) => {
                eprintln!("optchat: workspace {key} stays on the Chief's session: {e}");
                let _ = to.call(
                    json!({"cmd": "close-workspace", "key": key, "end_terminals": true,
                    "mutation_id": format!("optchat-adopt-undo-{key}"), "origin": MUTATION_ORIGIN}),
                );
            }
        }
    }
    Ok(moved)
}

/// Makes tree workspace `ws` (key `key`) in the user's session at `app` (connection `to`) with
/// its tabs, in the person's "Chief agents" group when `group` names it
/// (``place_in_personal_group``). Err when any chat tab could not be made.
fn copy_workspace(
    to: &mut LineClient,
    app: &Path,
    ws: &Value,
    key: &str,
    group: &str,
) -> Result<(), String> {
    let name = shown_name(ws["name"].as_str().unwrap_or(""));
    let made = to.call(json!({"cmd": "create-workspace", "key": key, "name": name,
        "mutation_id": format!("optchat-adopt-ws-{key}"), "origin": MUTATION_ORIGIN}))?;
    let workspace = made["workspace"].clone();
    let mut pane: Option<Value> = None;
    // Pages open after the chats, which make the workspace's first pane: a page
    // listed before any chat would otherwise have no pane to open in.
    let mut pages = Vec::new();
    for (i, tab) in tree_tabs(ws).iter().enumerate() {
        let conversation = &tab["conversation"];
        if tab["kind"] == "pty" {
            // Never a new shell for an old one: a workspace whose terminal runs a
            // command is not copied at all (`busy_terminal`), so every terminal here is
            // an idle shell or ended. Re-creating them made 369 idle shells (one host and
            // one PTY each) at one Chief start (a423, 2026-10-21).
            continue;
        } else if conversation.is_object() {
            let mut request = json!({"cmd": "new-conversation-tab",
                "mutation_id": format!("optchat-adopt-tab-{key}-{i}"), "origin": MUTATION_ORIGIN});
            match &pane {
                Some(p) => request["pane"] = p.clone(),
                None => request["workspace"] = workspace.clone(),
            }
            if let Some(session) = conversation["agent_session"].as_object() {
                let session: serde_json::Map<String, Value> = session
                    .iter()
                    .filter(|(_, v)| !v.is_null())
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                request["agent_session"] = Value::Object(session);
            } else {
                for field in ["page", "route", "conversation"] {
                    if !conversation[field].is_null() {
                        request[field] = conversation[field].clone();
                    }
                }
            }
            to.call(request)?;
            if pane.is_none() {
                pane = pane_of(to, key);
            }
        } else if tab["kind"] == "browser" {
            pages.push((i, tab.clone()));
        }
    }
    if pane.is_none() {
        pane = pane_of(to, key);
    }
    for (i, tab) in &pages {
        let Some(p) = pane.clone() else {
            eprintln!("optchat: workspace {key}: a page did not move: no pane");
            continue;
        };
        {
            let mut request = json!({"cmd": "new-frontend-browser-tab", "pane": p,
                "url": tab["url"].as_str().unwrap_or("about:blank"),
                "engine": tab["browser_engine"].as_str().unwrap_or("cef"), "activate": false,
                "idempotency_key": format!("optchat-adopt-page-{key}-{i}")});
            if let Some(profile) = tab["browser_profile_id"].as_str() {
                request["profile_id"] = json!(profile);
            }
            // Best effort: a page is not a chat.
            if let Err(e) = to.call(request) {
                eprintln!("optchat: workspace {key}: a page did not move: {e}");
            }
        }
    }
    if let Err(e) = place_in_personal_group(app, key, group) {
        eprintln!("optchat: workspace {key} stays ungrouped: {e}");
    }
    Ok(())
}

/// The first pane of workspace `key` in the session `to` reads.
fn pane_of(to: &mut LineClient, key: &str) -> Option<Value> {
    let tree = to.workspaces().ok()?;
    let ws = tree["workspaces"]
        .as_array()?
        .iter()
        .find(|w| w["key"] == key)?
        .clone();
    ws["screens"][0]["panes"][0].get("id").cloned()
}

/// `(id, name)` of each group in a group list answer.
fn groups_of(list: &Value) -> Vec<(String, String)> {
    list.as_array()
        .into_iter()
        .flatten()
        .filter_map(|g| Some((g["id"].as_str()?.to_owned(), g["name"].as_str()?.to_owned())))
        .collect()
}

/// The id of the existing group a workspace asked into `name` joins among `groups` (`(id,
/// name)`): only ``AGENTS_GROUP_NAME`` (any case) is joined, and only when the session has it.
/// None for any other name, an empty one, or no such group: the workspace stays ungrouped and
/// no group is made (#27712).
fn agents_group(name: &str, groups: &[(String, String)]) -> Option<String> {
    if !name.trim().eq_ignore_ascii_case(AGENTS_GROUP_NAME) {
        return None;
    }
    groups
        .iter()
        .find(|(_, g)| g.trim().eq_ignore_ascii_case(AGENTS_GROUP_NAME))
        .map(|(id, _)| id.clone())
}
