//! The Chief's live view of the person's Home workspace (cx-ebm.59.2, Lawrence 2026-10-14:
//! "chief needs to be able to have live context on what's happening on right side").
//!
//! Home is the app's daemon home workspace (`workspace.ensure_home`, `extra.kind: home`): the
//! Chief's chat docked on the left, a normal workspace on its right. Each turn gets one bounded
//! text block that names that workspace's panes and tabs (public ids, the ones the `cmux` CLI
//! takes), each terminal's title, folder and last screen lines, each browser's title and URL, and
//! each agent's state. It goes after the view and before the new messages, so the cached prefix
//! never changes, and it is never logged: the memory does not grow with it, and the next turn
//! reads a new one. `chief workspace` prints the same block, so a turn can read it again after it
//! acts.
//!
//! The reads are the bundled CLI's own (`session current snapshot`, `terminal <id> screen read`),
//! run by its `cmux-tui` name (`HomeView::cli_for`), on the app's daemon: the same ids and the
//! same trust as the Chief's own `cmux` calls. Without a home workspace (no app: `cmux chief`
//! started the brain) there is no block. A read that fails gives one line that says so; a turn
//! never fails because of it.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::panic_free::JsonFields;

/// The block's tag.
pub const TAG: &str = "cmux-home-workspace";
/// The largest block, in bytes; what does not fit is counted at the end.
pub const MAX_BYTES: usize = 6 * 1024;
/// Panes shown, left to right.
const MAX_PANES: usize = 8;
/// Tabs shown per pane.
const MAX_TABS: usize = 6;
/// Screen lines shown of each pane's selected terminal.
const TAIL_LINES: usize = 12;
/// Characters kept of one screen line or title.
const LINE_CHARS: usize = 160;
/// Longest one CLI read may take.
const READ_LIMIT: Duration = Duration::from_millis(1500);
/// Longest all the reads of one block may take: a turn never waits longer for it.
const TOTAL_LIMIT: Duration = Duration::from_millis(2500);

/// How to read the app's daemon: the `cmux` CLI and the env that pins it there
/// (`cmux_env::pin`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HomeView {
    pub cli: PathBuf,
    pub env: BTreeMap<String, String>,
}

impl HomeView {
    /// From this process's own env (a turn's `chief workspace`): the bundled CLI the host
    /// pinned (`CMUX_BUNDLED_CLI_PATH`, `cli_for`); the env is inherited.
    pub fn from_env() -> HomeView {
        let bundled = crate::cli::env(crate::cmux_env::BUNDLED_CLI_KEY).filter(|p| !p.is_empty());
        HomeView {
            cli: Self::cli_for(bundled.as_deref().map(Path::new)),
            env: BTreeMap::new(),
        }
    }

    /// The CLI the reads run: the `cmux-tui` beside the bundled `cmux` (the same binary of the
    /// same build). The `cmux` name is the curated CLI, which refuses the `session` scope
    /// (`"session" is not part of cmux`); the `cmux-tui` name keeps the full grammar that the
    /// app's own tooling uses. Without a bundled CLI, or with no `cmux-tui` beside it:
    /// `cmux-tui` on PATH.
    pub fn cli_for(bundled_cmux: Option<&Path>) -> PathBuf {
        let name = format!("cmux-tui{}", std::env::consts::EXE_SUFFIX);
        bundled_cmux
            .and_then(Path::parent)
            .map(|dir| dir.join(&name))
            .filter(|beside| beside.is_file())
            .unwrap_or_else(|| PathBuf::from(name))
    }

    /// The block for this turn: None when the daemon has no home workspace.
    pub fn read(&self) -> Option<String> {
        match self.build() {
            Ok(view) => view,
            Err(reason) => Some(format!(
                "<{TAG} unavailable: {}>",
                clip(&reason, LINE_CHARS)
            )),
        }
    }

    fn build(&self) -> Result<Option<String>, String> {
        let deadline = Instant::now() + TOTAL_LIMIT;
        let snapshot = self.json(&["--json", "session", "current", "snapshot"], deadline)?;
        let Some(home) = Home::find(&snapshot) else {
            return Ok(None);
        };
        // The shown panes' screens, read at the same time within the same deadline.
        let tails: Vec<Option<String>> = std::thread::scope(|scope| {
            let reads: Vec<_> = home
                .right
                .iter()
                .take(MAX_PANES)
                .map(|pane| {
                    let terminal = pane.selected().and_then(|tab| tab.terminal.clone());
                    scope.spawn(move || {
                        let terminal = terminal?;
                        match self.json(
                            &["--json", "terminal", &terminal, "screen", "read"],
                            deadline,
                        ) {
                            Ok(screen) => screen.get("text").and_then(Value::as_str).map(tail),
                            Err(reason) => {
                                Some(format!("(screen not read: {})", clip(&reason, 80)))
                            }
                        }
                    })
                })
                .collect();
            reads
                .into_iter()
                .map(|read| read.join().unwrap_or(None))
                .collect()
        });
        Ok(Some(home.render(&tails)))
    }

    /// One `cmux` read as JSON, within READ_LIMIT: the child's stdout reaching its end is the
    /// event; past the limit the child is killed.
    fn json(&self, args: &[&str], deadline: Instant) -> Result<Value, String> {
        let limit = READ_LIMIT.min(deadline.saturating_duration_since(Instant::now()));
        if limit.is_zero() {
            return Err("no time left for this turn's reads".into());
        }
        let what = || {
            format!(
                "cmux {}",
                args.iter()
                    .filter(|a| !a.starts_with("--"))
                    .take(3)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" ")
            )
        };
        let mut child = Command::new(&self.cli)
            .args(args)
            .envs(&self.env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{}: {e}", self.cli.display()))?;
        let (mut stdout, mut stderr) = (child.stdout.take(), child.stderr.take());
        // stderr drains on its own thread, so a chatty CLI never fills its pipe and stalls.
        let errors = std::thread::spawn(move || {
            let mut err = String::new();
            if let Some(stderr) = stderr.as_mut() {
                let _ = stderr.by_ref().take(64 * 1024).read_to_string(&mut err);
                // The rest is read and dropped, so the pipe never fills.
                let _ = std::io::copy(stderr, &mut std::io::sink());
            }
            err
        });
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut out = Vec::new();
            if let Some(stdout) = stdout.as_mut() {
                let _ = stdout.read_to_end(&mut out);
            }
            let _ = tx.send(out);
        });
        let Ok(out) = rx.recv_timeout(limit) else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{} took over {limit:?}", what()));
        };
        let status = child.wait().map_err(|e| e.to_string())?;
        if !status.success() {
            let err = errors.join().unwrap_or_default();
            return Err(format!("{}: {}", what(), err.trim()));
        }
        serde_json::from_slice(&out).map_err(|e| format!("{}: {e}", what()))
    }
}

/// One tab of a pane.
#[derive(Debug, Default)]
struct Tab {
    id: String,
    selected: bool,
    /// Its terminal's id (a terminal tab).
    terminal: Option<String>,
    line: String,
}

/// One pane, left to right.
#[derive(Debug, Default)]
struct Pane {
    id: String,
    focused: bool,
    tabs: Vec<Tab>,
}

impl Pane {
    fn selected(&self) -> Option<&Tab> {
        self.tabs
            .iter()
            .find(|tab| tab.selected)
            .or(self.tabs.first())
    }
}

/// The home workspace's shown screen: its dock (the Chief's chat) and the panes on its right.
#[derive(Debug, Default)]
struct Home {
    workspace: String,
    screen: String,
    dock: Vec<String>,
    right: Vec<Pane>,
}

impl Home {
    fn find(snapshot: &Value) -> Option<Home> {
        let list = |key: &str| {
            snapshot
                .get(key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let text = |value: &Value, key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let flag =
            |value: &Value, key: &str| value.get(key).and_then(Value::as_bool).unwrap_or(false);
        let workspace = list("workspaces")
            .into_iter()
            .find(|w| *w.field("extra").field("kind") == "home")?;
        let workspace_id = text(&workspace, "id");
        let screens: Vec<Value> = list("screens")
            .into_iter()
            .filter(|s| s["workspace_id"] == workspace_id.as_str())
            .collect();
        // A Home with no screen yet (nothing opened in it) still gets its block.
        let Some(screen) = screens
            .iter()
            .find(|s| flag(s, "focused"))
            .or(screens.first())
            .cloned()
        else {
            return Some(Home {
                workspace: workspace_id,
                ..Home::default()
            });
        };
        let screen_id = text(&screen, "id");
        // Panes in the order the layout draws them; the dock column's panes apart.
        let mut order = Vec::new();
        let mut dock = Vec::new();
        walk(
            screen.field("layout").field("root"),
            false,
            &mut order,
            &mut dock,
        );
        let panes: Vec<Value> = list("panes")
            .into_iter()
            .filter(|p| p["screen_id"] == screen_id.as_str())
            .collect();
        for pane in &panes {
            let id = text(pane, "id");
            if !order.contains(&id) && !dock.contains(&id) {
                order.push(id);
            }
        }
        let tabs = list("tabs");
        let terminals = list("terminals");
        let browsers = list("browsers");
        let agents = list("agents");
        let right = order
            .into_iter()
            .filter(|id| !dock.contains(id))
            .filter_map(|id| {
                let pane = panes.iter().find(|p| p["id"] == id.as_str())?;
                let mut own: Vec<&Value> = tabs
                    .iter()
                    .filter(|t| t["pane_id"] == id.as_str())
                    .collect();
                own.sort_by_key(|t| t["index"].as_u64().unwrap_or(0));
                let tabs = own
                    .into_iter()
                    .map(|tab| {
                        let kind = text(tab, "content_kind");
                        let content = text(tab, "content_id");
                        let mut row = Tab {
                            id: text(tab, "id"),
                            selected: flag(tab, "focused"),
                            ..Tab::default()
                        };
                        row.line = match kind.as_str() {
                            "terminal" => {
                                let terminal =
                                    terminals.iter().find(|t| t["id"] == content.as_str());
                                row.terminal = Some(content.clone());
                                let mut line = format!("terminal {content}");
                                if let Some(t) = terminal {
                                    line.push_str(&format!(
                                        " \"{}\"",
                                        quoted(&text(t, "title"), LINE_CHARS)
                                    ));
                                    if let Some(cwd) = t.get("cwd").and_then(Value::as_str) {
                                        line.push_str(&format!(" in {}", clip(cwd, 400)));
                                    }
                                    if !flag(t, "running") {
                                        line.push_str(" (exited)");
                                    }
                                }
                                if let Some(agent) =
                                    agents.iter().find(|a| a["terminal_id"] == content.as_str())
                                {
                                    line.push_str(&format!(", agent {}", text(agent, "state")));
                                }
                                line
                            }
                            "browser" => {
                                let browser = browsers.iter().find(|b| b["id"] == content.as_str());
                                let mut line = format!("browser {content}");
                                if let Some(b) = browser {
                                    line.push_str(&format!(
                                        " \"{}\" {}",
                                        quoted(&text(b, "title"), LINE_CHARS),
                                        clip(&text(b, "url"), 400)
                                    ));
                                    if flag(b, "loading") {
                                        line.push_str(" (loading)");
                                    }
                                }
                                line
                            }
                            other => {
                                let name =
                                    tab.get("name").and_then(Value::as_str).unwrap_or_default();
                                format!("{other} \"{}\"", quoted(name, LINE_CHARS))
                            }
                        };
                        row
                    })
                    .collect();
                Some(Pane {
                    id,
                    focused: flag(pane, "focused"),
                    tabs,
                })
            })
            .collect();
        Some(Home {
            workspace: workspace_id,
            screen: screen_id,
            dock,
            right,
        })
    }

    /// The block: the workspace, its shown screen and dock pane, then the panes on the right;
    /// `tails[i]` is the screen tail of `right[i]`'s selected terminal.
    /// How to read and use it is in the system prompt (`prompt::HOME_RULE`), which is cached:
    /// only what changes goes here, after the turn's cache mark (cx-4a5w2).
    fn render(&self, tails: &[Option<String>]) -> String {
        let head = format!(
            "<{TAG} workspace={}{}{}>\n",
            self.workspace,
            if self.screen.is_empty() {
                String::new()
            } else {
                format!(" screen={}", self.screen)
            },
            match self.dock.as_slice() {
                [] => String::new(),
                docks => format!(" dock={}", docks.join(",")),
            }
        );
        let foot = if self.right.is_empty() {
            format!("Nothing is open on the right yet.\n</{TAG}>")
        } else {
            format!("</{TAG}>")
        };
        let budget = MAX_BYTES.saturating_sub(head.len() + foot.len() + 64);
        let mut body = String::new();
        let mut left_out = 0usize;
        for (index, pane) in self.right.iter().enumerate() {
            let mut part = format!(
                "pane {}{}\n",
                pane.id,
                if pane.focused { " (focused)" } else { "" }
            );
            for tab in pane.tabs.iter().take(MAX_TABS) {
                part.push_str(&format!(
                    "  {} {}{}\n",
                    tab.id,
                    tab.line,
                    if tab.selected { " [shown]" } else { "" }
                ));
            }
            if pane.tabs.len() > MAX_TABS {
                part.push_str(&format!("  … {} more tabs\n", pane.tabs.len() - MAX_TABS));
            }
            if index >= MAX_PANES || body.len() + part.len() > budget {
                left_out += 1;
                continue;
            }
            // The screen tail takes its share of the room left (every shown pane after it keeps
            // its own share), its newest lines first.
            if let Some(Some(tail)) = tails.get(index) {
                let panes_left = self.right.len().min(MAX_PANES).saturating_sub(index).max(1);
                let room = (budget - body.len() - part.len()) / panes_left;
                let mut kept: Vec<String> = Vec::new();
                let mut used = 0;
                for line in tail.lines().rev() {
                    let line = format!("    | {line}\n");
                    if used + line.len() > room {
                        break;
                    }
                    used += line.len();
                    kept.push(line);
                }
                kept.reverse();
                part.extend(kept);
            }
            body.push_str(&part);
        }
        if left_out > 0 {
            body.push_str(&format!(
                "… {left_out} more panes (cmux --json session current snapshot)\n"
            ));
        }
        format!("{head}{body}{foot}")
    }
}

/// Collects the pane ids under `node` in drawing order; `in_dock` marks a docked column's.
fn walk(node: &Value, in_dock: bool, order: &mut Vec<String>, dock: &mut Vec<String>) {
    let mut push = |id: &Value| {
        if let Some(id) = id.as_str() {
            if in_dock {
                dock.push(id.to_owned())
            } else {
                order.push(id.to_owned())
            }
        }
    };
    if let Some(id) = node.get("pane_id") {
        push(id);
    }
    if let Some(ids) = node.get("pane_ids").and_then(Value::as_array) {
        ids.iter().for_each(&mut push);
    }
    for key in ["first", "second"] {
        if let Some(child) = node.get(key) {
            walk(child, in_dock, order, dock);
        }
    }
    if let Some(columns) = node.get("columns").and_then(Value::as_array) {
        for column in columns {
            // The chat's dock: the agent chat role, else a left dock. A dock on another edge is
            // a pane on the right like any other.
            let docked = column
                .get("dock")
                .is_some_and(|d| d["role"] == "agent_chat" || d["edge"] == "left");
            walk(&column["root"], in_dock || docked, order, dock);
        }
    }
}

/// The last TAIL_LINES non-empty lines of a screen, each clipped.
fn tail(screen: &str) -> String {
    let lines: Vec<&str> = screen
        .lines()
        .map(str::trim_end)
        .filter(|l| !l.is_empty())
        .collect();
    let start = lines.len().saturating_sub(TAIL_LINES);
    lines
        .iter()
        .skip(start)
        .map(|l| clip(l, LINE_CHARS))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A title for inside the block's quotes: clipped, with its own `"` as `”`.
fn quoted(text: &str, chars: usize) -> String {
    clip(text, chars).replace('"', "”")
}

/// `text` cut to `chars` characters, with an ellipsis when cut. Control characters are dropped
/// and `<` becomes `‹`, so text from a terminal or a page can never open or close a tag of the
/// block.
fn clip(text: &str, chars: usize) -> String {
    let clean: String = text
        .chars()
        .filter(|c| !c.is_control() || *c == '\t')
        .map(|c| if c == '<' { '‹' } else { c })
        .collect();
    if clean.chars().count() <= chars {
        return clean;
    }
    let mut out: String = clean.chars().take(chars.saturating_sub(1)).collect();
    out.push('…');
    out
}
