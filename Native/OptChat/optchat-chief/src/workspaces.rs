//! Each subagent's cmux workspace (Lawrence, 2026-10-05: "subagent
//! orchestration spawns workspaces that have the acp chat, so everything is
//! monitorable and I can jump in deeper using cmux ui"). A workspace named
//! after the subagent's task, whose selected tab is the agent chat of the
//! SAME acpmux session the Chief drives: the user watches its chat and tool
//! calls live and can write to it. It is named `aN · Short title` and goes
//! into a sidebar group named by its topic. It stays after the subagent
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
/// Characters of a workspace title, after the `aN · ` prefix.
const TITLE_CHARS: usize = 32;

/// Where subagents' workspaces are made.
pub trait Workspaces: Send + Sync {
    /// Opens workspace `key` (a fresh `new_key`, chosen before the session
    /// starts so the session can carry it as CMUX_WORKSPACE_ID) named `name`
    /// in the sidebar group named `group` (made when missing; best effort),
    /// whose tab is acpmux session `session`'s chat (a terminal in `cwd`
    /// beside it); returns its key.
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
    /// Where its workspaces live, for the Chief to tell the user (for
    /// example "the cmux app on this Mac").
    fn place(&self) -> String;
    /// The public id (`ws_…`) and session name of workspace `key`, so the
    /// Chief and the user can list, move and pin it with the cmux CLI
    /// (`cmux --session <session> workspace <ws_…> move --index 0`); None
    /// when this place cannot name it.
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
    /// The CLI command that moves this workspace to the top of its session.
    pub fn move_to_top(&self) -> String {
        format!(
            "cmux --session {} workspace {} move --index 0",
            self.session, self.id
        )
    }
}

/// A subagent's workspace name: its id and a short title of its task.
pub fn name(id: &str, task: &str) -> String {
    format!("{id} · {}", title(task))
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

/// Topic groups for subagent workspaces and the words that pick them; the
/// first match wins (Lawrence 2026-10-19: "you need to group it better as
/// well").
pub const TOPICS: &[(&str, &[&str])] = &[
    (
        "Crashes & QA",
        &[
            "crash", "crashes", "sentry", "fuzz", "qa", "tester", "testers",
        ],
    ),
    (
        "Performance",
        &[
            "perf",
            "performance",
            "bench",
            "benchmark",
            "latency",
            "power",
            "wakeups",
            "memory",
            "cpu",
        ],
    ),
    (
        "Markdown & editor",
        &["markdown", "monaco", "editor", "mermaid"],
    ),
    (
        "Home & chat",
        &[
            "home", "imessage", "composer", "chat", "chats", "dm", "dms", "messages",
        ],
    ),
    (
        "Browser & parity",
        &[
            "browser",
            "chrome",
            "chromium",
            "webkit",
            "web",
            "webview",
            "omnibar",
            "extension",
            "extensions",
            "cookie",
            "cookies",
        ],
    ),
    (
        "Sidebar & tabs",
        &[
            "sidebar",
            "tab",
            "tabs",
            "unread",
            "hover",
            "workspace",
            "workspaces",
            "group",
            "groups",
        ],
    ),
    (
        "Panes & layout",
        &[
            "pane", "panes", "split", "splits", "divider", "resize", "layout", "window",
        ],
    ),
    (
        "Nightly & CI",
        &["nightly", "nightlies", "ci", "release", "landing"],
    ),
    (
        "Agents & routing",
        &[
            "acpmux",
            "chief",
            "agent",
            "agents",
            "subagent",
            "subagents",
            "subrouter",
            "sr2",
            "claude",
            "codex",
            "acp",
        ],
    ),
    (
        "Cloud & fleet",
        &[
            "cloud",
            "fleet",
            "vm",
            "vms",
            "mini",
            "minis",
            "tailscale",
            "server",
        ],
    ),
];

/// The group of subagent workspaces no topic matches.
pub const AGENTS_GROUP_NAME: &str = "Chief agents";

/// The sidebar group for `task`: its `Group:` line, else the first of
/// ``TOPICS`` whose words appear in its title, else in its first line, else
/// ``AGENTS_GROUP_NAME``.
pub fn topic_group(task: &str) -> String {
    if let Some(g) = header(task, "group") {
        return g;
    }
    for text in [title(task), first_line(task).to_owned()] {
        let words: Vec<String> = text
            .to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(str::to_owned)
            .collect();
        let topic = TOPICS
            .iter()
            .find(|(_, keys)| keys.iter().any(|k| words.iter().any(|w| w == k)));
        if let Some((name, _)) = topic {
            return (*name).to_owned();
        }
    }
    AGENTS_GROUP_NAME.to_owned()
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

/// The id the fallback group is made with (Lawrence 2026-10-18: "use groups
/// more aggressively so that you can organize and the user feels less
/// overwhelmed"). A fixed id makes the create idempotent: the daemon answers
/// the stored group for the same id and name.
pub const AGENTS_GROUP_ID: &str = "chief-agents";
/// The daemon capability of workspace groups.
const GROUPS: &str = "workspace-groups-v1";

/// The id a topic group named `name` is made with when the session has none
/// by that name: `chief-agents` for the fallback, else `chief-topic-<slug>`.
pub fn group_id(name: &str) -> String {
    if name == AGENTS_GROUP_NAME {
        return AGENTS_GROUP_ID.to_owned();
    }
    let slug: String = name
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    format!("chief-topic-{slug}")
}

/// Puts `workspace` in the group named `name` (any case): the session's own
/// group by that name when it has one (the user's groups are reused), else
/// one made with ``group_id``. Only a failed move is an error.
/// `workspace` None moves it by its key (a workspace the app made).
fn group_workspace(
    client: &mut cmux::raw::Client,
    workspace: Option<u64>,
    key: &str,
    name: &str,
) -> Result<(), String> {
    use cmux::raw::{
        CreateWorkspaceGroupRequest, ListWorkspaceGroupsRequest, MoveWorkspaceToGroupRequest,
        Optional,
    };
    let existing = client
        .list_workspace_groups(ListWorkspaceGroupsRequest {})
        .ok()
        .and_then(|listed| {
            listed["groups"].as_array()?.iter().find_map(|g| {
                let named = g["name"].as_str()?.trim().eq_ignore_ascii_case(name.trim());
                named.then(|| g["id"].as_str().map(str::to_owned)).flatten()
            })
        });
    let group = match existing {
        Some(id) => id,
        None => {
            let id = group_id(name);
            let _ = client.create_workspace_group(CreateWorkspaceGroupRequest {
                collapsed: None,
                color: Optional::Missing,
                group: Optional::Value(id.clone()),
                index: Optional::Missing,
                name: name.to_owned(),
            });
            id
        }
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
}

impl DaemonWorkspaces {
    fn client(&self) -> Result<cmux::raw::Client, String> {
        use cmux::raw::{Client, ClientConfig};
        Client::connect(ClientConfig::from_socket_path(&self.daemon))
            .map_err(|e| format!("the session daemon: {e}"))
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
            AgentSessionSource, CreateTerminalRequest, CreateWorkspaceRequest,
            NewConversationTabRequest, Optional,
        };
        const TABS: &str = "agent-session-tabs-v1";
        let mut client = self.client()?;
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
            if groups {
                // Best effort: a sidebar group never fails the subagent's start.
                if let Err(e) = group_workspace(&mut client, Some(workspace), &key, group) {
                    eprintln!("optchat: subagent workspace {key} stays ungrouped: {e}");
                }
            }
            let placement = client
                .create_terminal(CreateTerminalRequest {
                    workspace: Optional::Value(workspace),
                    cwd: Optional::Value(cwd.display().to_string()),
                    mutation_id: Optional::Value(format!("optchat-subagent-term-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("create-terminal: {e}"))?;
            let pane = placement
                .pane
                .into_option()
                .ok_or("create-terminal placed no pane")?;
            client
                .new_conversation_tab(NewConversationTabRequest {
                    pane: Optional::Value(pane),
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
        result.map(|()| key)
    }

    fn close(&self, key: &str) -> Result<(), String> {
        close_by_key(&self.daemon, key)
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        rename_by_key(&self.daemon, key, name)
    }

    fn locate(&self, key: &str) -> Option<WorkspaceRef> {
        locate_by_key(&self.daemon, key)
    }

    fn place(&self) -> String {
        // The Chief home's own owner daemon (tabs on `chief:<home id>`): the app shows it
        // as the Chief's machine row.
        if self.host.starts_with("chief:") {
            return "the Chief's own cmux session on this Mac (the cmux app shows it under the Chief)"
                .to_owned();
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
    let id = tree?["workspaces"]
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
/// Closes workspace `key` and ends its terminal (the subagent's shell); the
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
