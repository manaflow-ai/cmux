//! Each subagent's cmux workspace (Lawrence, 2026-10-05: "subagent
//! orchestration spawns workspaces that have the acp chat, so everything is
//! monitorable and I can jump in deeper using cmux ui"). A workspace named
//! after the subagent's task, whose selected tab is the agent chat of the
//! SAME acpmux session the Chief drives: the user watches its chat and tool
//! calls live and can write to it. It is named after its task's short title,
//! like any workspace (Leo 2026-10-21: no `aN · ` id in the sidebar; the id is
//! the Chief's own), and goes into a sidebar group named by its topic. It stays after the subagent
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

use crate::panic_free::JsonFields;

/// The app action that opens a session's chat in a new workspace.
pub const OPEN_ACTION: &str = "agent.openSessionWorkspace";
/// Characters of a workspace title.
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
    let preamble = ["the user", "user", "redo of", "follow-up to", "context"]
        .iter()
        .any(|p| {
            strip_prefix_ignore_case(s, p)
                .is_some_and(|rest| rest.chars().next().is_none_or(|c| !c.is_alphanumeric()))
        });
    if preamble {
        return after_mark(s, &[':', ',', '.']).to_owned();
    }
    for product in ["cmux-next", "cmux next"] {
        if let Some(rest) = strip_prefix_ignore_case(s, product) {
            let rest = rest.trim_start();
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

/// `s` after an ASCII `prefix` matched without regard to case.
fn strip_prefix_ignore_case<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    let (head, rest) = s.split_at_checked(prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then_some(rest)
}

/// What follows the first of `marks` outside parentheses; empty when none.
fn after_mark<'a>(s: &'a str, marks: &[char]) -> &'a str {
    let closing = marks.contains(&')');
    let mut depth = 0i32;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if !closing {
            match c {
                '(' => depth = depth.saturating_add(1),
                ')' => depth = depth.saturating_sub(1),
                _ => {}
            }
        }
        if depth <= 0 && marks.contains(&c) {
            return chars.as_str().trim();
        }
    }
    ""
}

/// The first clause of `s`: up to a sentence end, a colon, a quote, a
/// parenthesis or an embedded "User" preamble.
fn cut_clause(s: &str) -> String {
    let clause = [
        ". ", ": ", "; ", " — ", " - ", "? ", "! ", " (", "\"", " User", " user (", " user:",
    ]
    .iter()
    .filter_map(|mark| s.split_once(mark).map(|(head, _)| head))
    .filter(|head| !head.is_empty())
    .min_by_key(|head| head.len())
    .unwrap_or(s);
    clause
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
        let kept = match head.rsplit_once(' ') {
            Some((words, _)) if !whole && words.len() >= TITLE_CHARS / 2 => words,
            _ => head.as_str(),
        };
        format!("{}…", kept.trim_end_matches([',', ';', ':', ' ']))
    };
    let mut chars = out.chars();
    if let Some(c) = chars.next()
        && c.is_lowercase()
        && !out.starts_with("cmux")
    {
        out = c.to_uppercase().chain(chars).collect();
    }
    out
}

/// Topic groups for subagent workspaces and the words that pick them; the
/// first match wins (Lawrence 2026-10-19: "you need to group it better as
/// well"). The words cover the groups a137 still moved spawns into by hand
/// on 2026-10-20 (acp-chief-issues.md #9): lag is Performance, iOS, UI and
/// migrations are the cmux-next app.
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
            "lag",
            "laggy",
            "slow",
            "fast",
            "faster",
            "speed",
            "10x",
            "100x",
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
        &[
            "nightly",
            "nightlies",
            "ci",
            "release",
            "landing",
            "push",
            "lint",
            "quality",
            "gate",
        ],
    ),
    (
        "cmux-next app",
        &[
            "ui",
            "ios",
            "iphone",
            "mobile",
            "migration",
            "onboarding",
            "dialog",
            "dialogs",
            "settings",
        ],
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
            "pairing",
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
    uuid_v4(bytes)
}

/// `random` as an RFC 4122 version 4 UUID (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`).
pub(crate) fn uuid_v4(mut random: [u8; 16]) -> String {
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    let n = u128::from_be_bytes(random);
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        n >> 96,
        (n >> 80) & 0xffff,
        (n >> 64) & 0xffff,
        (n >> 48) & 0xffff,
        n & 0xffff_ffff_ffff
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
/// ordinary workspace there, made with the same daemon ops, grouped by its topic and owned by
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
    let link_of = |id: &str| session_of(id).and_then(|s| subagent_link(parent, id, &s));
    let mut out = String::with_capacity(text.len());
    let mut behind = Behind::default();
    let keep = |out: &mut String, behind: &mut Behind, piece: &str| {
        out.push_str(piece);
        behind.push(piece);
    };
    let mut fence = false;
    let mut rest = text;
    while !rest.is_empty() {
        if behind.line_start()
            && let Some(after) = rest.strip_prefix("```")
        {
            fence = !fence;
            keep(&mut out, &mut behind, "```");
            rest = after;
            continue;
        }
        let mut chars = rest.chars();
        let Some(c) = chars.next() else { break };
        let after = chars.as_str();
        let mut one = [0u8; 4];
        let first: &str = c.encode_utf8(&mut one);
        if fence {
            keep(&mut out, &mut behind, first);
            rest = after;
            continue;
        }
        match c {
            // An inline code span: to its closing backtick on this line.
            '`' => match after
                .split_once('`')
                .filter(|(code, _)| !code.contains('\n'))
            {
                Some((code, tail)) => {
                    for piece in ["`", code, "`"] {
                        keep(&mut out, &mut behind, piece);
                    }
                    rest = tail;
                }
                None => {
                    keep(&mut out, &mut behind, "`");
                    rest = after;
                }
            },
            '[' => match after
                .split_once(']')
                .filter(|(label, _)| !label.contains('\n'))
            {
                // An existing link: skip it whole.
                Some((label, tail)) if tail.starts_with('(') => {
                    for piece in ["[", label, "]"] {
                        keep(&mut out, &mut behind, piece);
                    }
                    rest = match tail.split_once(')') {
                        Some((target, after_link)) => {
                            keep(&mut out, &mut behind, target);
                            keep(&mut out, &mut behind, ")");
                            after_link
                        }
                        None => tail,
                    };
                }
                Some((label, tail)) => {
                    match is_id(label).then(|| link_of(label)).flatten() {
                        Some(link) => {
                            out.push_str(&link);
                            behind.push("[");
                            behind.push(label);
                            behind.push("]");
                        }
                        None => {
                            for piece in ["[", label, "]"] {
                                keep(&mut out, &mut behind, piece);
                            }
                        }
                    }
                    rest = tail;
                }
                None => {
                    keep(&mut out, &mut behind, "[");
                    rest = after;
                }
            },
            'a' if behind.emphasis_open()
                || behind.last().is_none_or(|p| {
                    !(word(p) || matches!(p, '/' | '.' | '-' | ':' | '#' | '@'))
                }) =>
            {
                let tail = after.trim_start_matches(|d: char| d.is_ascii_digit());
                let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
                let id = format!("a{digits}");
                let bounded = !digits.is_empty() && (emphasis_close(tail) || !continues_word(tail));
                match (bounded && is_id(&id)).then(|| link_of(&id)).flatten() {
                    Some(link) => {
                        out.push_str(&link);
                        behind.push(&id);
                    }
                    None => keep(&mut out, &mut behind, &id),
                }
                rest = tail;
            }
            _ => {
                keep(&mut out, &mut behind, first);
                rest = after;
            }
        }
    }
    out
}

/// A Markdown word character for `link_subagents`: an id inside a longer token stays as written.
fn word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// Whether `tail`, the text right after an id, continues its token (`a1b`, `a1.txt`).
fn continues_word(tail: &str) -> bool {
    let mut next = tail.chars();
    match next.next() {
        None => false,
        Some('.') => next.next().is_some_and(word),
        Some(c) => word(c),
    }
}

/// Whether `tail` starts with a `_`/`__` emphasis closer (`_a1_`), not snake_case (`a1_x`).
fn emphasis_close(tail: &str) -> bool {
    let after = tail.trim_start_matches('_');
    let run = tail.len().saturating_sub(after.len());
    (1..=3).contains(&run)
        && after
            .chars()
            .next()
            .is_none_or(|c| !c.is_ascii_alphanumeric())
}

/// The text `link_subagents` has passed (as written, not the links it wrote for it): its last
/// character and the run of underscores it ends with.
#[derive(Default)]
struct Behind {
    underscores: usize,
    last_other: Option<char>,
}

impl Behind {
    fn push(&mut self, piece: &str) {
        for c in piece.chars() {
            if c == '_' {
                self.underscores = self.underscores.saturating_add(1);
            } else {
                self.underscores = 0;
                self.last_other = Some(c);
            }
        }
    }

    fn last(&self) -> Option<char> {
        if self.underscores > 0 {
            Some('_')
        } else {
            self.last_other
        }
    }

    fn line_start(&self) -> bool {
        self.last().is_none_or(|c| c == '\n')
    }

    /// Whether the text ends with a `_`/`__` emphasis opener (`_a1_`, `__a1__`), not snake_case
    /// (`foo_a1`): the underscores follow the start, a space or punctuation.
    fn emphasis_open(&self) -> bool {
        (1..=3).contains(&self.underscores)
            && self.last_other.is_none_or(|c| !c.is_ascii_alphanumeric())
    }
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
    open_request_on(session, name, key, cwd, Some(&chief_host(home)))
}

/// The `action.run` request that opens `session` in workspace `key`.
pub fn open_request(session: &str, name: &str, key: &str, cwd: &Path) -> Value {
    open_request_on(session, name, key, cwd, None)
}

/// `open_request`, its tab naming `host` as its session's host when given.
fn open_request_on(session: &str, name: &str, key: &str, cwd: &Path, host: Option<&str>) -> Value {
    let mut args =
        json!({"session": session, "name": name, "key": key, "cwd": cwd.display().to_string()});
    if let Some(host) = host {
        args.insert("host", json!(host));
    }
    json!({
        "id": 1,
        "method": "action.run",
        "params": {
            "action": OPEN_ACTION,
            "args": args,
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
            listed.field("groups").as_array()?.iter().find_map(|g| {
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
        request.insert("idempotency_key", json!(key));
    }
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    for answer in BufReader::new(stream).lines() {
        let answer = answer.map_err(|e| format!("reading the daemon's answer: {e}"))?;
        let Ok(value) = serde_json::from_str::<Value>(&answer) else {
            continue;
        };
        if *value.field("id") != json!(id) {
            continue;
        }
        return match value.field("ok").as_bool() {
            Some(true) => Ok(value.field("result").clone()),
            _ => Err(value
                .field("error")
                .field("message")
                .as_str()
                .map_or_else(|| value.field("error").to_string(), str::to_owned)),
        };
    }
    Err("the session daemon closed the connection".to_owned())
}

/// Puts workspace `key` of the user's session (the app's daemon at `daemon`) in that
/// session's personal sidebar group named `name` (any case), made when missing: the
/// `workspace_group.list`, `workspace_group.create` and `workspace.place` operations `cmux
/// workspace group <g> add` sends, so it sits in a group exactly as a workspace the user
/// grouped does (a423).
pub fn place_in_personal_group(daemon: &Path, key: &str, name: &str) -> Result<(), String> {
    let here = || json!({"machine": "current", "session": "current"});
    let listed = resource_call(daemon, "workspace_group.list", here(), None)?;
    let existing = listed.as_array().and_then(|groups| {
        groups.iter().find_map(|g| {
            let named = g["name"].as_str()?.trim().eq_ignore_ascii_case(name.trim());
            named.then(|| g["id"].as_str().map(str::to_owned)).flatten()
        })
    });
    let group = match existing {
        Some(id) => id,
        None => {
            let mut params = here();
            params.insert("name", json!(name));
            let made = resource_call(
                daemon,
                "workspace_group.create",
                params,
                Some(&format!("optchat-subagent-group-create-{key}")),
            )?;
            // A mutation answers `{value: <the group>, revision, …}`.
            made.field("value")
                .field("id")
                .as_str()
                .or_else(|| made.field("id").as_str())
                .ok_or("workspace_group.create named no group")?
                .to_owned()
        }
    };
    let workspace = locate_by_key(daemon, key)
        .ok_or("the session does not list the new workspace")?
        .id;
    let mut params = here();
    params.insert("workspace", json!(workspace));
    params.insert("group", json!(group));
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
            // Best effort: a sidebar group never fails the subagent's start.
            let grouped = if self.personal {
                place_in_personal_group(&self.daemon, &key, group)
            } else if groups {
                group_workspace(&mut client, Some(workspace), &key, group)
            } else {
                Ok(())
            };
            if let Err(e) = grouped {
                eprintln!("optchat: subagent workspace {key} stays ungrouped: {e}");
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
        // The app's daemon (tabs on `chief:<home id>`, the Chief home's acpmux): the user's
        // own session, beside the workspaces the user made (a423).
        if self.host.starts_with("chief:") {
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
    let id = tree?
        .field("data")
        .field("workspaces")
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
        request.insert("id", json!(self.next));
        let what = request
            .field("cmd")
            .as_str()
            .unwrap_or("request")
            .to_owned();
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
            if *value.field("id") != json!(self.next) {
                continue;
            }
            return match value.field("ok").as_bool() {
                Some(true) => Ok(value.field("data").clone()),
                _ => Err(format!(
                    "{what}: {}",
                    value
                        .field("error")
                        .field("message")
                        .as_str()
                        .map_or_else(|| value.field("error").to_string(), str::to_owned)
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
        let live = *t.field("kind") == "pty" && *t.field("dead") != json!(true);
        let title = t.field("title").as_str().unwrap_or("").to_owned();
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
        let task = r.trim_start_matches(|c: char| c.is_ascii_digit());
        let digits = r.len().saturating_sub(task.len());
        (1..=6).contains(&digits).then_some(task)
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
/// chat on the same acpmux session, each terminal as a new shell in the same directory, each
/// page) and the user's personal group of the same name. The old one closes (to the owner's
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
    let group_names: std::collections::HashMap<String, String> = tree
        .field("groups")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|g| Some((g["id"].as_str()?.to_owned(), g["name"].as_str()?.to_owned())))
        .collect();
    let held: std::collections::HashSet<String> = to
        .workspaces()?
        .field("workspaces")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| w["key"].as_str().map(str::to_owned))
        .collect();
    let mut moved = 0;
    // Bottom first: the user's session lists each new workspace first, so the order holds.
    let workspaces: Vec<Value> = tree
        .field("workspaces")
        .as_array()
        .cloned()
        .unwrap_or_default();
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
        let group = ws["group"]
            .as_str()
            .and_then(|g| group_names.get(g))
            .cloned()
            .unwrap_or_else(|| AGENTS_GROUP_NAME.to_owned());
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
/// its tabs, in personal group `group`. Err when any chat tab could not be made.
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
    let workspace = made.field("workspace").clone();
    let mut pane: Option<Value> = None;
    for (i, tab) in tree_tabs(ws).iter().enumerate() {
        let conversation = &tab["conversation"];
        if tab["kind"] == "pty" {
            let cwd = tab["cwd"].as_str().unwrap_or("/");
            let placed = to.call(json!({"cmd": "create-terminal", "workspace": workspace,
                "cwd": cwd, "mutation_id": format!("optchat-adopt-term-{key}-{i}"),
                "origin": MUTATION_ORIGIN}))?;
            pane = pane.or_else(|| placed.get("pane").cloned().filter(|p| !p.is_null()));
        } else if conversation.is_object() {
            let mut request = json!({"cmd": "new-conversation-tab",
                "mutation_id": format!("optchat-adopt-tab-{key}-{i}"), "origin": MUTATION_ORIGIN});
            match &pane {
                Some(p) => request.insert("pane", p.clone()),
                None => request.insert("workspace", workspace.clone()),
            }
            if let Some(session) = conversation["agent_session"].as_object() {
                let session: serde_json::Map<String, Value> = session
                    .iter()
                    .filter(|(_, v)| !v.is_null())
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                request.insert("agent_session", Value::Object(session));
            } else {
                for field in ["page", "route", "conversation"] {
                    if !conversation[field].is_null() {
                        request.insert(field, conversation[field].clone());
                    }
                }
            }
            to.call(request)?;
            if pane.is_none() {
                pane = pane_of(to, key);
            }
        } else if tab["kind"] == "browser" {
            let Some(p) = pane.clone() else { continue };
            let mut request = json!({"cmd": "new-frontend-browser-tab", "pane": p,
                "url": tab["url"].as_str().unwrap_or("about:blank"),
                "engine": tab["browser_engine"].as_str().unwrap_or("cef"), "activate": false,
                "idempotency_key": format!("optchat-adopt-page-{key}-{i}")});
            if let Some(profile) = tab["browser_profile_id"].as_str() {
                request.insert("profile_id", json!(profile));
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
    let ws = tree
        .field("workspaces")
        .as_array()?
        .iter()
        .find(|w| w["key"] == key)?
        .clone();
    ws.field("screens")
        .item(0)
        .field("panes")
        .item(0)
        .get("id")
        .cloned()
}
