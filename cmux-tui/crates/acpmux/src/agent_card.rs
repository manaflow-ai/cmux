//! The "where you are" card: a short note every new chat gets on its rules channel (Claude's
//! system prompt, Codex's developer instructions, any other harness's first message) that says
//! where the agent runs (Local, cmux Cloud, cmux AutoCloud), what cmux lets it do in this chat
//! and what this machine has now. It is never a file in the person's folder.
//!
//! Leo (2026-11-25): "should we put a bit of a readme type note or anything at all on... like
//! the capabilities of the machine the agent it's on? or like an introductory note like \"Hi!
//! :) you're on cmux autocloud. :)\"", then "oh right there's maybe other stuff like letting
//! agents know ab other capabilities...?"
//!
//! The capability lines come from the chat's live tool servers ([`AgentTools::scoped`]): a
//! line shows only when its server is there, so a chat without computer use is never told it
//! has it. The text puts what never changes first and this machine's numbers last, so a prompt
//! cache keeps everything above them. [`refresh`] rewrites the numbers at every spawn (after a
//! resize, or a move to another machine). `cmux capabilities` and `cmux machine info` print the
//! same card and facts on demand, and `cmux capabilities` adds every Cloud size with its price
//! ([`can_get`]: what the agent can get beyond this machine and how to ask). [`SWITCH_ENV`]`=0` turns the card off.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;

use crate::agent_tools::{self, AgentTools};
use crate::context_inventory::{ContextPart, estimated_tokens};

/// `0` turns the card off (the daemon's env or the chat's profile env).
pub const SWITCH_ENV: &str = "CMUX_AGENT_CARD";
/// The card's context source, sent as `<cmux-card-context>` on the first-message channel.
pub const SOURCE: &str = "cmux-card";

/// Where the chat runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Place {
    /// The person's own computer.
    Local,
    /// A cmux Cloud machine the chat was put on.
    Cloud,
    /// A cmux Cloud machine an AutoCloud chat moved to, and moves back from, on its own.
    AutoCloud,
}

impl Place {
    /// This process's place: a Cloud VM ([`crate::cloud_host::is_cloud_vm`]) or Local, and
    /// AutoCloud on a Cloud VM for a chat with Auto on.
    pub fn here(auto: bool) -> Self {
        Self::of(crate::cloud_host::is_cloud_vm(), auto)
    }

    pub fn of(cloud: bool, auto: bool) -> Self {
        match (cloud, auto) {
            (true, true) => Place::AutoCloud,
            (true, false) => Place::Cloud,
            (false, _) => Place::Local,
        }
    }
}

/// This machine's numbers, read now.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MachineFacts {
    pub place: Place,
    pub vcpus: usize,
    pub ram_bytes: Option<u64>,
    pub disk_free_bytes: Option<u64>,
    pub disk_total_bytes: Option<u64>,
    /// The GPUs found (`/proc/driver/nvidia/gpus`, `/dev/nvidia*`, `/dev/dri/renderD*`); empty
    /// when there is none. Only read on Linux: elsewhere `None`, and the line says nothing.
    pub gpus: Option<Vec<String>>,
    /// The tools of [`TOOLS`] found on `PATH`, in that order.
    pub tools: Vec<String>,
}

/// Tools worth naming when found on `PATH`.
const TOOLS: &[&str] = &[
    "git", "gh", "node", "npm", "pnpm", "bun", "python3", "uv", "cargo", "go", "java", "docker",
    "swift", "clang", "gcc", "make", "rg", "jq",
];

impl MachineFacts {
    /// The facts for a chat working in `cwd` (its disk is the one the numbers are of).
    pub fn read(place: Place, cwd: &Path) -> Self {
        let (free, total) = disk(cwd).unzip();
        MachineFacts {
            place,
            vcpus: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
            ram_bytes: ram_bytes(),
            disk_free_bytes: free,
            disk_total_bytes: total,
            gpus: gpus(),
            tools: tools_on_path(std::env::var_os("PATH").as_deref()),
        }
    }

    /// One line: "This machine now: 4 vCPU, 7.8 GB RAM, 41 GB disk free of 64 GB. Tools: …".
    pub fn line(&self) -> String {
        let mut parts = vec![format!("{} vCPU", self.vcpus)];
        if let Some(ram) = self.ram_bytes {
            parts.push(format!("{} RAM", gb(ram)));
        }
        match (self.disk_free_bytes, self.disk_total_bytes) {
            (Some(free), Some(total)) => {
                parts.push(format!("{} disk free of {}", gb(free), gb(total)))
            }
            (Some(free), None) => parts.push(format!("{} disk free", gb(free))),
            _ => {}
        }
        match self.gpus.as_deref() {
            Some([]) => parts.push("no GPU".to_owned()),
            Some(gpus) => parts.push(format!("GPU: {}", gpus.join(", "))),
            None => {}
        }
        let mut line = format!("This machine now: {}.", parts.join(", "));
        if !self.tools.is_empty() {
            line.push_str(&format!(" Tools on PATH: {}.", self.tools.join(", ")));
        }
        if let Some(limits) = self.limits() {
            line.push(' ');
            line.push_str(&limits);
        }
        line
    }

    /// What the numbers mean for a heavy job on a Cloud machine: a build needing more RAM than
    /// it has gets killed, so size the job or the machine first.
    fn limits(&self) -> Option<String> {
        if self.place == Place::Local {
            return None;
        }
        let ram = self.ram_bytes?;
        let mut text = format!(
            "A build or test run needing more than {} RAM gets killed here: before a big one, resize this machine (`cmux vm resize`) or cap its jobs (e.g. `cargo build -j{}`, `make -j{}`).",
            gb(ram),
            self.vcpus,
            self.vcpus
        );
        if self.gpus.as_deref().is_some_and(<[String]>::is_empty) {
            text.push_str(
                " With no GPU, GPU work (CUDA, model training) runs on the CPU or not at all.",
            );
        }
        Some(text)
    }
}

#[cfg(target_os = "linux")]
fn gpus() -> Option<Vec<String>> {
    Some(gpus_in(Path::new("/proc/driver/nvidia/gpus"), Path::new("/dev")))
}

#[cfg(not(target_os = "linux"))]
fn gpus() -> Option<Vec<String>> {
    None
}

/// The GPUs under `nvidia` (one dir per GPU, its `information` file naming the model) and
/// `dev` (`nvidia0`…, else `renderD128`… for any other driver).
fn gpus_in(nvidia: &Path, dev: &Path) -> Vec<String> {
    let mut found: Vec<String> = std::fs::read_dir(nvidia)
        .into_iter()
        .flatten()
        .flatten()
        .map(|gpu| {
            std::fs::read_to_string(gpu.path().join("information"))
                .ok()
                .and_then(|info| {
                    info.lines().find_map(|l| l.strip_prefix("Model:")).map(|m| m.trim().to_owned())
                })
                .unwrap_or_else(|| "NVIDIA GPU".to_owned())
        })
        .collect();
    if !found.is_empty() {
        found.sort();
        return found;
    }
    let names: Vec<String> = std::fs::read_dir(dev)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    let nvidia_devs = names
        .iter()
        .filter(|n| {
            n.strip_prefix("nvidia")
                .is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
        })
        .count();
    if nvidia_devs > 0 {
        return vec!["NVIDIA GPU".to_owned(); nvidia_devs];
    }
    let dri = dev.join("dri");
    let render = std::fs::read_dir(dri)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("renderD"))
        .count();
    vec!["GPU (render node)".to_owned(); render]
}

fn gb(bytes: u64) -> String {
    let gb = bytes as f64 / 1e9;
    if gb < 10.0 { format!("{gb:.1} GB") } else { format!("{gb:.0} GB") }
}

fn tools_on_path(path: Option<&std::ffi::OsStr>) -> Vec<String> {
    let dirs: Vec<_> = path.map(|p| std::env::split_paths(p).collect()).unwrap_or_default();
    TOOLS
        .iter()
        .filter(|tool| dirs.iter().any(|d: &std::path::PathBuf| is_executable(&d.join(tool))))
        .map(|t| (*t).to_owned())
        .collect()
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn ram_bytes() -> Option<u64> {
    crate::server::peer_status::ram_total()
}

/// Free (to an unprivileged user) and total bytes of the filesystem holding `path`, or its
/// nearest existing parent.
fn disk(path: &Path) -> Option<(u64, u64)> {
    let path = path.ancestors().find(|p| p.exists())?;
    crate::disk_usage::statvfs(path).map(|root| (root.free, root.total))
}

/// One thing cmux lets the agent do, and the tool server it needs (`None`: always there).
struct Capability {
    id: &'static str,
    server: Option<&'static str>,
    /// Places it applies to; empty for all.
    places: &'static [Place],
    line: &'static str,
    detail: &'static str,
}

const CLOUD: &[Place] = &[Place::Cloud, Place::AutoCloud];

/// Every line the card may show, in the order it shows them.
const CAPABILITIES: &[Capability] = &[
    Capability {
        id: "browser",
        server: Some(agent_tools::CMUX_SERVER),
        places: &[],
        line: "Open a page in a cmux browser pane beside the chat and drive it (cmux-browser skill).",
        detail: "The `cmux` tools and `cmux browser` open, read, click and screenshot pages in a browser pane in the person's cmux window; they see it as you work.",
    },
    Capability {
        id: "rich-output",
        server: Some(agent_tools::CMUX_SERVER),
        places: &[],
        line: "This chat renders charts and diagrams: answer with a ```chart, ```vega-lite or ```mermaid block, not ASCII art; images and live HTML artifacts show too (cmux-rich-output skill).",
        detail: "Mermaid, Vega-Lite and ```chart blocks, KaTeX, images and live HTML cards render in the chat itself.",
    },
    Capability {
        id: "computer-use",
        server: Some(crate::computer_use::mcp::SERVER_NAME),
        places: &[],
        line: "Use the person's Mac screen, keyboard and mouse (computer use).",
        detail: "The computer-use tools see and drive a display of the person's Mac; prefer the browser pane or a CLI when one does the job.",
    },
    Capability {
        id: "computer-use-lease",
        server: Some(agent_tools::DESKTOP_LEASE_SERVER),
        places: &[],
        line: "Use a leased desktop with screen, keyboard and mouse (computer use).",
        detail: "The cmux-desktop tools drive a desktop leased for this chat.",
    },
    Capability {
        id: "ask",
        server: Some(crate::acpmux_mcp_names::SERVER_NAME),
        places: &[],
        line: "Ask the person a question with answer buttons (wrap_up's ask) instead of stopping.",
        detail: "wrap_up with `ask` and up to two answers draws a card; the click arrives as the person's next message.",
    },
    Capability {
        id: "secrets",
        server: Some(crate::secret_mcp::SERVER_NAME),
        places: &[],
        line: "Ask for a secret or a sudo password with a card (request_secret), never in chat.",
        detail: "request_secret shows a card; the value reaches you without entering the transcript.",
    },
    Capability {
        id: "background",
        server: Some(crate::acpmux_mcp_names::SERVER_NAME),
        places: &[],
        line: "Run long jobs in the background (bg_start, bg_output) and keep working.",
        detail: "bg_start runs a command detached; it survives a restart, and bg_output reads it.",
    },
    Capability {
        id: "helpers",
        server: Some(crate::acpmux_mcp_names::SERVER_NAME),
        places: &[],
        line: "Fork this chat or start helper agents (fork, new, send) for side work.",
        detail: "fork copies this conversation into a new chat; new starts another agent (any harness); send and inbox talk to them.",
    },
    Capability {
        id: "sub-sessions",
        server: Some(crate::subsession_mcp::SERVER_NAME),
        places: &[],
        line: "Start sub-sessions the person sees in the chat (start_session).",
        detail: "Sub-session tools start child chats shown under this one.",
    },
    Capability {
        id: "offers",
        server: Some(crate::offer_mcp::SERVER_NAME),
        places: &[],
        line: "Offer the person a follow-up chat as a card (offer_session, suggest_tasks).",
        detail: "offer_session and suggest_tasks draw cards the person starts with one click.",
    },
    Capability {
        id: "machines",
        server: Some(crate::acpmux_mcp_names::SERVER_NAME),
        places: &[],
        line: "Reach the person's other machines (machines, machine_exec, machine_read) and start a Cloud machine (machine_start).",
        detail: "machines lists the person's linked machines; machine_exec, machine_read and machine_edit work on them; machine_start makes a cmux Cloud machine of a size you pick.",
    },
    Capability {
        id: "move",
        server: None,
        places: &[],
        line: "This chat can move itself between Local, Cloud and AutoCloud (`cmux chat move --on local|cloud|auto`, or move_chat); its work comes along.",
        detail: "`cmux chat move --on PLACE` moves this chat (its own, with no SESSION): local is this Mac, cloud stays in cmux Cloud, auto is here while the Mac is up and in the Cloud while it sleeps; the conversation and the folder follow. `cmux vm move NAME` moves it to one named Cloud machine instead.",
    },
    Capability {
        id: "grow",
        server: None,
        places: CLOUD,
        line: "This machine grows on demand: when a build needs more CPU, RAM or disk, just run it, or have it resized (`cmux vm resize NAME --size small|medium|large|xlarge` or `--disk GIB`, up to 16 vCPU, 24 GB RAM, 256 GB disk; the person confirms). Never call it too small.",
        detail: "Sizes: small 2 vCPU/4 GB, medium 4/8, large 8/16, xlarge 16/24; disk 4 to 256 GB in 4 GB steps.",
    },
    Capability {
        id: "folders",
        server: None,
        places: CLOUD,
        line: "Ask for another Mac folder with `cmux link access request PATH`.",
        detail: "The person allows it in the app; the folder then appears on this machine and syncs back like this one.",
    },
    Capability {
        id: "repos",
        server: Some(crate::cloud_repo_mcp::SERVER_NAME),
        places: &[],
        line: "Add a GitHub repository to this machine through the team's grant (cmux-cloud-repos).",
        detail: "The cmux-cloud-repos tools clone a repository the team's cmux GitHub connection can read.",
    },
    Capability {
        id: "github",
        server: Some(crate::github_mcp::SERVER_NAME),
        places: &[],
        line: "Use GitHub through the team's cmux connection (github tools).",
        detail: "GitHub's own MCP server, with a token cmux mints for the team's connection.",
    },
    Capability {
        id: "shared-tools",
        server: Some(crate::hosted_mcp::SERVER_NAME),
        places: &[],
        line: "Use the person's shared tool servers (cmux-hosted).",
        detail: "The tool servers the signed-in person added in cmux, served to every chat.",
    },
    Capability {
        id: "memory",
        server: Some(agent_tools::MEMORY_SERVER_NAME),
        places: &[],
        line: "Search and keep notes in shared memory (cmux-agent-memory).",
        detail: "Memory shared by the person's agents across chats.",
    },
];

/// One enabled capability, for `cmux capabilities --json`.
#[derive(Debug, Clone, Serialize)]
pub struct Enabled {
    pub id: &'static str,
    pub line: &'static str,
    pub detail: &'static str,
}

/// The capabilities enabled for a chat at `place` whose tool servers are `servers` (none when
/// the chat gets no tools).
pub fn enabled(place: Place, servers: &[String]) -> Vec<Enabled> {
    CAPABILITIES
        .iter()
        .filter(|c| c.places.is_empty() || c.places.contains(&place))
        .filter(|c| c.server.is_none_or(|s| servers.iter().any(|n| n == s)))
        .map(|c| Enabled { id: c.id, line: c.line, detail: c.detail })
        .collect()
}

/// The tool servers a new chat with profile env `env` gets, read now: none for a remote origin
/// or `ACPMUX_AGENT_TOOLS=0` ([`agent_tools::left_out`]).
pub fn servers_for(remote_origin: bool, env: &BTreeMap<String, String>) -> Vec<String> {
    if agent_tools::left_out(remote_origin, env, &[]) {
        return Vec::new();
    }
    let mut tools: AgentTools = agent_tools::current();
    tools.displays = None;
    tools.scoped(env).servers.into_iter().map(|s| s.name).collect()
}

fn intro(place: Place) -> &'static str {
    match place {
        Place::Local => {
            "You're in cmux, on the person's own computer. Your edits land in their folder directly."
        }
        Place::Cloud => {
            "You're on cmux Cloud: a Linux machine cmux runs for the person. The folder you work in is their Mac folder, projected here: your edits sync back to the Mac on their own, so nothing needs copying back and \"it stays on this VM\" is wrong."
        }
        Place::AutoCloud => {
            "You're on cmux AutoCloud: cmux moved this chat from the person's Mac to a Linux Cloud machine and moves it back when the Mac returns. The folder you work in is their Mac folder, projected here: your edits sync back to the Mac on their own, so nothing needs copying back and \"it stays on this VM\" is wrong."
        }
    }
}

/// The card's text: what never changes first, then what the agent can get
/// ([`can_get::CanGet::lines`]), then this machine's numbers.
pub fn render(facts: &MachineFacts, enabled: &[Enabled], can_get: &can_get::CanGet) -> String {
    let mut text = String::from("<where-you-are>\n");
    text.push_str(intro(facts.place));
    text.push_str("\nWhat cmux lets you do in this chat (details: `cmux capabilities`):\n");
    for c in enabled {
        text.push_str("- ");
        text.push_str(c.line);
        text.push('\n');
    }
    text.push_str(&can_get.lines());
    // Last, so a prompt cache keeps everything above it when only the numbers change.
    text.push_str(&facts.line());
    text.push_str(" (`cmux machine info` reads them again.)\n</where-you-are>");
    text
}

/// Whether the card is off for a chat with profile env `env`.
pub fn off(env: &BTreeMap<String, String>) -> bool {
    let off = |v: &str| matches!(v.trim(), "0" | "false" | "off");
    env.get(SWITCH_ENV).is_some_and(|v| off(v)) || std::env::var(SWITCH_ENV).is_ok_and(|v| off(&v))
}

/// The card for a new chat, read now, or `None` when it is off or the chat is a remote
/// client's (which gets no cmux context at all).
pub fn for_session(
    cfg: &crate::config::Config,
    harness: &str,
    cwd: &Path,
    remote_origin: bool,
    auto: bool,
) -> Option<String> {
    let env = cfg.harnesses.get(harness).map(|p| p.env.clone()).unwrap_or_default();
    for_env(&env, cwd, remote_origin, auto)
}

/// [`for_session`] for a chat whose profile env is `env`.
pub fn for_env(
    env: &BTreeMap<String, String>,
    cwd: &Path,
    remote_origin: bool,
    auto: bool,
) -> Option<String> {
    if remote_origin || off(env) {
        return None;
    }
    let place = Place::here(auto);
    let facts = MachineFacts::read(place, cwd);
    Some(render(
        &facts,
        &enabled(place, &servers_for(remote_origin, env)),
        &can_get::CanGet::read(),
    ))
}

/// The card as a context part on `channel`.
pub fn part_on(text: String, channel: &str) -> ContextPart {
    ContextPart {
        id: SOURCE.into(),
        source: SOURCE.into(),
        label: "Where you are: cmux capabilities and this machine".into(),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(text.len() as u64),
        channel: Some(channel.into()),
        text: Some(text.into()),
    }
}

/// Rewrite the card in `parts` for this machine now (a spawn after a resize or a move), on the
/// channel it was captured on. True when the text changed. A chat captured without a card
/// gets none.
pub fn refresh(
    parts: &mut [ContextPart],
    env: &BTreeMap<String, String>,
    cwd: &Path,
    auto: bool,
) -> bool {
    let Some(part) = parts.iter_mut().find(|p| p.source == SOURCE) else { return false };
    let Some(text) = for_env(env, cwd, false, auto) else { return false };
    if part.text.as_deref() == Some(text.as_str()) {
        return false;
    }
    let channel = part.channel.clone().unwrap_or_default();
    *part = part_on(text, &channel);
    true
}

/// `cmux capabilities [--json]` and `cmux machine info [--json]` on this machine, for a chat
/// in `cwd` with the daemon's own env.
pub fn cli(what: &str, json: bool, cwd: &Path) -> String {
    let auto = std::env::var("CMUX_AUTOCLOUD").is_ok_and(|v| v == "1");
    let place = Place::here(auto);
    let facts = MachineFacts::read(place, cwd);
    let env = BTreeMap::new();
    let caps = enabled(place, &servers_for(false, &env));
    let more = can_get::CanGet::read();
    match (what, json) {
        ("machine", true) => serde_json::to_string_pretty(&facts).unwrap_or_default(),
        ("machine", false) => facts.line(),
        (_, true) => serde_json::to_string_pretty(&serde_json::json!({
            "place": place,
            "machine": facts,
            "capabilities": caps,
            "can_get": more,
        }))
        .unwrap_or_default(),
        _ => {
            let mut out = render(&facts, &caps, &more);
            out.push_str("\n\nDetails:\n");
            for c in &caps {
                out.push_str(&format!("- {}: {}\n", c.id, c.detail));
            }
            out.push('\n');
            out.push_str(&more.table());
            out
        }
    }
}

#[path = "agent_card_can_get.rs"]
pub mod can_get;

#[cfg(test)]
#[path = "agent_card_tests.rs"]
mod tests;
