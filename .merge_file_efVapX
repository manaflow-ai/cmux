//! Progressive, catalog-backed documentation for agents and scripts.

use std::borrow::Cow;
use std::io::{self, Write};
use std::sync::OnceLock;

use serde::Serialize;
use serde_json::Value;

use super::{GlobalArgs, OutputMode, UsageError};

mod guide;

#[derive(Clone, Debug)]
pub(super) struct Plan {
    pub(super) request: Request,
    pub(super) output: OutputMode,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Request {
    /// `cmux docs search QUERY`: operations, task guides and guide pages.
    Search(String),
    /// `cmux docs guide [SLUG | --full]`: the cmux NEXT guide pages.
    Guide(guide::Request),
}

/// Claims the local `docs` command before the resource parser sees it.
pub(super) fn command(
    args: &[String],
    global: GlobalArgs,
) -> Result<Option<super::command::ParsedCommand>, UsageError> {
    if args.first().map(String::as_str) != Some("docs") {
        return Ok(None);
    }
    let rest = args.get(1..).unwrap_or_default();
    if rest.iter().any(|arg| matches!(arg.as_str(), "-h" | "--help")) {
        return Ok(Some(super::command::ParsedCommand::Help(Some("docs".to_owned()))));
    }
    Ok(Some(super::command::ParsedCommand::Docs(parse(rest, global.output)?)))
}

pub(super) fn append_scope_help(scope: &str, text: Cow<'static, str>) -> Cow<'static, str> {
    if has_scope_operations(scope) {
        Cow::Owned(format!("{}\n{}", text, scope_help(scope)))
    } else {
        text
    }
}

/// A task an agent searches for in words of its own, which no one operation
/// answers: the operations and app actions for it, in one paragraph. `cmux
/// docs search` and the MCP `cmux_docs` tool return the guides one of whose
/// keywords is a word of the query.
#[derive(Clone, Copy, Debug, Serialize)]
pub(super) struct Guide {
    pub(super) topic: &'static str,
    #[serde(skip)]
    keywords: &'static [&'static str],
    pub(super) text: &'static str,
}

pub(super) const GUIDES: &[Guide] = &[
    Guide {
        topic: "Show your work to the user without moving their focus",
        keywords: &[
            "show",
            "user",
            "person",
            "visible",
            "see",
            "focus",
            "steal",
            "status",
            "progress",
            "report",
            "chat",
            "conversation",
            "notify",
            "attention",
        ],
        text: "Open an agent session's chat: the app action agent.openSessionWorkspace (MCP \
        app_agent_open {session, group}, CLI `cmux agent open SESSION [--group G]`) opens that \
        session's chat in a new workspace, in sidebar group G (made when missing) when given; \
        the workspace the user looks at stays. agent.openSessionTab (MCP app_agent_open_tab \
        {session, target}, CLI `cmux agent open-tab SESSION [--target T]`) opens it as a tab of the \
        target pane (a pane or tab id; default the focused pane) and selects it only with focus: \
        true; a session a tab already shows gets no second tab. Open a link: \
        workspace_open_url {url, workspace} loads it in a browser tab on the workspace's right \
        side and keeps the keyboard focus, but it navigates a browser tab already there, so \
        when the user's page must stay use browser_profile_open {url, profile: \"default\", pane, \
        activate: false} (CLI `cmux browser profile open URL --profile default --background \
        true`), which adds a tab and keeps the pane's selected tab. Post \
        status on a workspace's sidebar row: workspace_status_set {workspace, key, text, state, \
        progress, ttl_ms} (CLI `cmux workspace WS status set KEY TEXT`), workspace_progress_set \
        and workspace_log_append; clear them when the work is done. Ask for attention: \
        notification_create {title, body} (desktop: false shows no banner). When the user must \
        act in a tab (confirm, log in, approve, pick), mark it: tab_update {tab, attention: \
        \"one-line reason\"} (CLI `cmux attention request --tab TAB --reason TEXT`); it never \
        moves focus, and tab_update {tab, attention: null} (`cmux attention clear --tab TAB`) \
        drops it. Tell the user the workspace and tab by their titles, never a ws_ or tab_ id. \
        The focus tools \
        (tab_focus, pane_focus, screen_focus, workspace_focus, agents_tab_select) and focus: true \
        move the user's focus: use them only when the user asked. The selector `current` is what \
        the user looks at, not your own workspace.",
    },
    Guide {
        topic: "Check a hover, scroll or typing fix in a chat, in the person's own build",
        keywords: &[
            "hover", "scroll", "wheel", "typing", "type", "flicker", "rerender", "render",
            "composer", "verify", "nightly", "release", "drive", "pointer",
        ],
        text: "`cmux app chat drive --tab TAB` (every build, Nightly and Release too) drives one \
        agent chat tab's page without moving the system pointer and without focusing, raising or \
        showing its window: --hover TEST_ID, --hover-sent-image N or --hover-tool-screenshot N \
        rests a pointer on that element and holds it (the page gets a real :hover and opens its \
        hover card); --wheel N [--delta PX] sends N trusted wheel ticks to the transcript under \
        it; --type TEXT types into the composer one character a frame and leaves the text in \
        the draft (nothing is restored; it refuses a non-empty draft unless --over-draft). It \
        reports each frame (--json): composer renders and DOM mutations, focus, :focus-within \
        and page-inactive flips, hover and card state, frame times, and Chromium's layout and \
        style counts when the chat shows in Chromium. It refuses a chat whose turn is running \
        unless --allow-busy, stops within --seconds (at most 30), and runs no script: a fixed set \
        of actions. Its counters exist only for the run. A covered, hidden or screen-locked chat \
        draws no frames, and the report says it measured nothing. `cmux app chat perf --tab TAB` \
        measures a chat left alone.",
    },
    Guide {
        topic: "Set up cmux for the person: trust, harnesses, machines, accounts",
        keywords: &[
            "setup",
            "configure",
            "install",
            "onboard",
            "onboarding",
            "trust",
            "login",
            "signin",
            "harness",
            "outdated",
            "peer",
            "enroll",
            "machine",
            "ssh",
            "mcp",
            "computer",
            "grant",
            "cloud",
            "notifications",
            "bookmarks",
            "cookies",
        ],
        text: "`cmux setup list` names every setup task (folder trust, harness install and sign-in, \
        ssh machines, peer updates, accounts, Cloud machines, Tailscale, pairing tickets, MCP \
        wiring, Computer Use, browser import, key bindings, notifications, team invites) with \
        the read-only \
        commands that check it, the commands that do it, and what only the person can do. \
        `cmux setup local` is one safe first-chat pass: it trusts the current folder, checks \
        harnesses, and wires the cmux MCP server only when the existing setting allows it; its \
        report contains all three task results and their undo commands. `cmux setup status` \
        checks the tasks setup runs. `cmux setup trust [FOLDER]` records \
        trust for a folder; it changes nothing when the folder is already trusted, --dry-run \
        prints the plan, and every result names its undo command. `cmux setup machine \
        SSH_TARGET [--name NAME]` adds an ssh machine as an acpmux peer (`cmux acp host \
        setup`), updates a peer on an older build (`cmux acp host update`), and is ok when the \
        peer is connected and current; it uses key-only ssh, and a host it cannot reach comes \
        back as needs_user with the ssh command to try. `cmux setup harness [ID ...]` reports \
        whether each harness (default: every configured or found one) is installed, signed in \
        and outdated; a missing CLI or sign-in is needs_user with the install docs or `cmux \
        harness login ID`. `cmux setup mcp [claude|codex ...]` gives Claude Code and Codex \
        started outside cmux the cmux MCP server through their own `mcp add`; agents started \
        in cmux get cmux's tools unless the person turns `agents.cmuxMcp` off (Settings > \
        Agents). `cmux setup computer-use` turns Computer Use \
        on once the person allows it on the sheet cmux shows, and names each missing macOS \
        grant with the command that opens its System Settings pane. `cmux setup \
        cloud-machine` is ok when cmux shows a Cloud machine; otherwise, once the person is \
        signed in, it creates one after the person allows it on the card cmux shows (it costs \
        money every hour it runs). It keeps the request and reads cmux's list before anything \
        else, so a rerun adopts the machine that appeared, waits for one on its way, and never \
        creates a second; kind wait means run it again later, kind declined means ask first, \
        kind many_machines means setup claims none, inferred: true means check the machine \
        with the person before the undo, and its undo is `cmux cloud kill-machine --target \
        machine:ID --confirm && cmux setup cloud-machine --forget` (--forget drops setup's \
        record so it may ask again). `cmux setup notifications` lets cmux show macOS \
        notifications: it shows the macOS prompt once, and when they are denied or their alert \
        style is None names the command that opens cmux's page in System Settings > \
        Notifications. `cmux setup browser-import --browser BROWSER[:PROFILE]` \
        imports that browser's bookmarks (ok when any profile of it is in, or the named one; \
        the undo removes the folders the run added); with \
        --cookies it imports its sign-ins once the person allows it on the panel cmux shows, \
        and that has no undo. History and passwords come in only from Import from Browser... \
        in cmux. `cmux setup tailnet [--owner LOGIN]` serves this machine to the person's \
        other machines over Tailscale (what `cmux host enable` does; undo `cmux host disable \
        --json`); until Tailscale runs it names the person's one step (kind install, start, \
        sign_in, approve or wait), and a tagged node with no owner is kind owner. \
        `cmux setup status` lists every peer with connected and outdated, every \
        harness, the MCP wiring, Computer Use, the Cloud machine, notifications, the \
        imported browsers and the tailnet. Every `cmux setup` command prints one JSON object: state is ok, \
        changed, planned, needs_user, failed or not_applicable.",
    },
    Guide {
        topic: "Set up cmux with Chief: copyable setup prompts",
        keywords: &[
            "setup",
            "prompt",
            "prompts",
            "chief",
            "copy",
            "paste",
            "starter",
            "remote",
            "tailnet",
            "tailscale",
            "pair",
            "pairing",
            "ticket",
        ],
        text: "Every task `cmux setup list` names has a `prompt`: one paragraph a person pastes \
        into Chief, or any agent chat in cmux, that names the exact command to run, what to hand \
        the person and what to reply; its `status_prompt` sets up this Mac in one local pass \
        (`cmux setup local`) and leaves Cloud, tailnet and other machines for explicit approval. \
        docs/chief-setup-prompts.md has them as copyable blocks \
        (`cmux setup list --prompts-md` writes it). A pasted prompt is the person's request for \
        that task: run its command. Words left in capitals (HOST, FOLDER, BROWSER, EMAIL) are \
        the person's to fill in, so ask for them. Remote machines: `cmux setup machine HOST` adds \
        a Mac on the tailnet or any ssh host as an agent peer, and `cmux acp host doctor NAME \
        [--fix]` checks or repairs one; `cmux host ticket new` mints a single-use line that \
        installs cmux on another machine and joins it (`cmux host join`) without ssh; `cmux \
        setup tailnet` serves this machine over Tailscale.",
    },
    Guide {
        topic: "Start, prompt and drive another agent chat in the app",
        keywords: &[
            "agent",
            "agents",
            "start",
            "spawn",
            "delegate",
            "subagent",
            "message",
            "nudge",
            "continue",
            "interrupt",
            "stop",
            "model",
            "effort",
            "screenshot",
            "capture",
            "attach",
            "attachment",
        ],
        text: "Start an ordinary agent chat the user sees in the app, as New Agent Chat and a \
        first message do, without moving their focus: `cmux agents chat new [--workspace WS | \
        --pane PANE] [--harness claude|codex|...] [--model M] [--effort \
        low|medium|high|xhigh|max] [--mode M] [--policy ask|approve-reads|deny-all] [--cwd DIR] \
        [--name N] [--attach FILE]... -- PROMPT` (MCP agents_chat_new, attachments: absolute \
        paths); with neither --workspace nor --pane it gets a new workspace. --attach sends a \
        file of any type and size with PROMPT (`cmux chat --attach FILE TEXT` too); a send to a \
        running chat carries text only (chat.attach_send_unsupported). It runs in the app's own acpmux (not as your subagent) and PROMPT is its \
        first prompt, as if the user typed it. Its receipt names the chat (an acpmux session \
        id), tab, pane and workspace. Drive a chat of this cmux session (never your own): `cmux \
        agents chat send CHAT -- TEXT` (agents_chat_send, an agent message), `chat read CHAT \
        --after N` (agents_chat_read), `chat state CHAT` (agents_chat_state: status, running, \
        pending permissions), `chat interrupt CHAT` (agents_chat_interrupt, stops its turn) and \
        `chat continue CHAT [TEXT]` (a nudge). Wait for its answer with agents_wait or read on \
        from next_after. See a pane or tab: `cmux pane screenshot --target pane_ID --out PATH` or \
        `cmux tab screenshot --target tab_ID --out PATH` (browser pages come out blacked out; a \
        browser page's own pixels are `cmux browser page screenshot`).",
    },
    Guide {
        topic: "Script cmux Computer Use: several app steps in one cmux_exec call",
        keywords: &["cu", "computer", "desktop", "gui"],
        text: "In cmux_exec, `cu.<tool>(args)` is `cmux.cu_<tool>(args)` (cmux Computer Use, \
        built in): pass a known title or app name as window_id. Use list_windows for discovery. Chain \
        reads and actions with loops and conditions in ONE script. Each call is its own \
        Computer Use call (its own call id, the person's settings and approval cards apply to \
        each). In a script an acting call skips its settle screenshot unless you pass \
        observe: true; read back with get_ui_tree or screenshot instead. A tool's result is its \
        JSON, plus `images: [{type: \"image\", image: N}]` when it has a screenshot; only the \
        images your script returns reach you as images (return r or r.images). A \
        refused call (computer_use_off, app_denied, look_only, person_in_control) throws: stop \
        and tell the person which setting in Settings > Computer Use would allow it. \
        `cu.find(tree, {role, name})` finds an element in a get_ui_tree result (a RegExp \
        matches, `cu.findAll` lists, `cu.elements(tree)` flattens); act on its `id` as \
        element_id. Roles are plain: button, text_field, text, checkbox, link. \
        Fill and submit a form: `const t = await cu.get_ui_tree({window_id: \"Sign up\"}); \
        const window_id = t.window_id; \
        await cu.set_value({window_id, element_id: cu.find(t, {role: \"text_field\", name: \
        /email/i}).id, value: \"ada@example.com\"}); await cu.click({window_id, element_id: \
        cu.find(t, {role: \"button\", name: \"Submit\"}).id}); return await \
        cu.screenshot({window_id});` (the screenshot comes back as an image) \
        Click until a condition holds: `for (let i = 0; i < 10; i++) { const t = await \
        cu.get_ui_tree({window_id}); if (cu.find(t, {name: \"Done\"})) return {pages: i}; const \
        next = cu.find(t, {role: \"button\", name: \"Next\"}); if (!next) return {stuck: i}; \
        await cu.click({window_id, element_id: next.id}); await cu.wait({window_id, ms: 300}); } \
        return {pages: 10, done: false};` \
        Read a value out of a window: `const t = await cu.get_ui_tree({window_id}); return \
        cu.find(t, {role: \"text\", name: /total/i})?.value;` \
        Return small values (the one field you need), not whole trees. \
        A fixed run of steps on one window can also be one `cu.batch({window_id, actions})`: \
        each step gets its own outcome; `require: \"confirmed\"` stops the batch unless that \
        step read back; `{action: \"wait_for\", target: {role: \"sheet\"}}` waits for a sheet \
        (or `until: \"disappears\"`, `value_equals`, `value_contains`); `target: {role, label}` \
        acts on an element by what it is, refused when two match. The reply's results list \
        every step (done, failed or not_run) and stopped_at says which step stopped it.",
    },
    Guide {
        topic: "Build on cmux: which primitive to use",
        keywords: &[
            "primitive",
            "primitives",
            "api",
            "sdk",
            "terminal",
            "browser",
            "extend",
            "extension",
            "integrate",
            "integration",
            "automate",
            "automation",
            "automations",
            "event",
            "events",
            "trigger",
            "cron",
            "action",
            "actions",
            "resource",
            "resources",
            "protocol",
        ],
        text: "cmux is built from five primitives; use the smallest one that does the job. \
        Resources and operations: every noun (workspace, pane, tab, terminal, browser, \
        notification) has a stable prefixed id (ws_, pane_, tab_, term_) and typed verbs named \
        noun_verb, such as workspace_create, workspace_list, workspace_run, tab_create_terminal, \
        tab_create_browser and tab_update. Each one returns a typed result or a coded error. \
        The same operations are `cmux <noun> <verb>` on the CLI and cmux.protocol/2 for SDKs, so \
        a script, an agent and an app all call one API. \
        Events: agents_events long-polls what changed (tabs, workspaces, notifications, dialogs, \
        agent states). Pass its next_after cursor on the next call to get no gaps or \
        duplicates, and pass until/match to wait for one event. Never poll a list. \
        Actions: a menu item, palette item or shortcut is an app action. Each action the app \
        offers outside the GUI is one app_* tool (app_agent_open) and `cmux action run ID`. Use \
        one only when no operation does the job. \
        Automations: when (an event such as agent-idle, a schedule, or a watch command) + if (a \
        shell condition) + do (a prompt or a command), with a record of each run. \
        automation_events lists the events, automation_create makes an automation, \
        automation_test checks it and automation_runs reads what ran. \
        Composition: one cmux_exec script calls any of these in a single turn, with the same \
        rights as a direct call and no more.",
    },
];

/// The guides for `query` (see [`Guide`]).
pub(super) fn guides(query: &str) -> Vec<Guide> {
    let terms = query
        .split(|c: char| c.is_whitespace() || matches!(c, '_' | '.' | '-'))
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>();
    GUIDES
        .iter()
        .filter(|guide| guide.keywords.iter().any(|keyword| terms.iter().any(|t| t == keyword)))
        .copied()
        .collect()
}

#[derive(Clone, Debug, Serialize)]
struct SearchResult {
    name: String,
    class: String,
    target: String,
    selectors: Vec<String>,
    fields: Vec<String>,
    result: String,
}

#[derive(Serialize)]
struct SearchResponse {
    query: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    guides: Vec<Guide>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pages: Vec<GuidePage>,
    results: Vec<SearchResult>,
}

/// A guide page a search found: its title and the command that prints it.
#[derive(Clone, Debug, Serialize)]
pub(super) struct GuidePage {
    pub(super) slug: String,
    pub(super) title: String,
    pub(super) read: String,
}

/// The cmux NEXT guide pages that answer `query` (`cmux docs search` and the MCP `cmux_docs` tool).
pub(super) fn guide_pages(query: &str) -> Vec<GuidePage> {
    guide::matching(query)
        .into_iter()
        .map(|page| GuidePage {
            slug: page.slug.clone(),
            title: page.title.clone(),
            read: format!("cmux docs guide {}", page.slug),
        })
        .collect()
}

fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(cmux_tui_core::packed_catalogs::RESOURCE_OPERATIONS_V2)
            .expect("the checked-in resource operation catalog")
    })
}

pub(super) fn parse(args: &[String], output: OutputMode) -> Result<Plan, UsageError> {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("search") => {
            let query = rest.join(" ").trim().to_owned();
            if query.is_empty() {
                return Err(UsageError::new("docs search needs a query"));
            }
            Ok(Plan { request: Request::Search(query), output })
        }
        Some("guide") => Ok(Plan { request: Request::Guide(guide::parse(rest)?), output }),
        Some(other) => Err(UsageError::new(format!(
            "unknown docs command {other}; use `cmux docs guide` or `cmux docs search <query>`"
        ))),
        None => Err(UsageError::new(
            "missing docs command; use `cmux docs guide` or `cmux docs search <query>`",
        )),
    }
}

pub(super) fn help() -> &'static str {
    "USAGE\n  cmux docs guide [SLUG | --full] [--json]\n  cmux docs search <query> [--json]\n\n\
     guide prints the cmux NEXT guide: how the app, its daemons, agents, machines, Cloud and the\n\
     vault fit together, and how to use them. With no SLUG it lists the pages; --full prints\n\
     every page as one Markdown file.\n\
     search finds catalog operations, task guides and guide pages for a query.\n\
     Both work without connecting to a cmux session.\n"
}

pub(super) fn run(plan: Plan) -> i32 {
    let query = match plan.request {
        Request::Guide(request) => return guide::run(&request, plan.output),
        Request::Search(query) => query,
    };
    let results = search(&query);
    let guides = guides(&query);
    let pages = guide_pages(&query);
    let response = SearchResponse { query, guides, pages, results };
    let mut stdout = io::stdout().lock();
    match plan.output {
        OutputMode::Quiet => {}
        OutputMode::Json | OutputMode::JsonLines => {
            let _ = serde_json::to_writer(&mut stdout, &response);
            let _ = stdout.write_all(b"\n");
        }
        OutputMode::Human => {
            let _ = writeln!(stdout, "cmux docs search: {}", response.query);
            for guide in &response.guides {
                let _ = writeln!(stdout, "  Guide: {}\n    {}", guide.topic, guide.text);
            }
            for page in &response.pages {
                let _ = writeln!(stdout, "  Page: {} (`{}`)", page.title, page.read);
            }
            if response.results.is_empty() {
                let _ = writeln!(stdout, "No matching operations.");
            } else {
                for result in response.results {
                    let selectors = if result.selectors.is_empty() {
                        String::new()
                    } else {
                        format!(" selectors: {}", result.selectors.join(", "))
                    };
                    let fields = if result.fields.is_empty() {
                        String::new()
                    } else {
                        format!(" fields: {}", result.fields.join(", "))
                    };
                    let _ = writeln!(
                        stdout,
                        "  {} [{}] target: {}{}{} -> {}",
                        result.name, result.class, result.target, selectors, fields, result.result
                    );
                }
            }
        }
    }
    let _ = stdout.flush();
    0
}

fn search(query: &str) -> Vec<SearchResult> {
    let terms = query.split_whitespace().map(|term| term.to_ascii_lowercase()).collect::<Vec<_>>();
    let operations = catalog()["operations"].as_object().expect("catalog operations object");
    let mut matches = operations
        .iter()
        .filter_map(|(name, descriptor)| {
            let haystack = serde_json::to_string(&(name, descriptor)).ok()?.to_ascii_lowercase();
            if !terms.iter().all(|term| haystack.contains(term)) {
                return None;
            }
            Some((score(name, &haystack, &terms), result(name, descriptor)))
        })
        .collect::<Vec<_>>();
    matches.sort_by(|(left_score, left), (right_score, right)| {
        right_score.cmp(left_score).then_with(|| left.name.cmp(&right.name))
    });
    matches.into_iter().take(20).map(|(_, result)| result).collect()
}

fn score(name: &str, haystack: &str, terms: &[String]) -> usize {
    terms
        .iter()
        .map(|term| {
            let mut score = if name.to_ascii_lowercase().contains(term) { 10 } else { 0 };
            if haystack.starts_with(term) {
                score += 1;
            }
            score
        })
        .sum()
}

fn result(name: &str, descriptor: &Value) -> SearchResult {
    let params = descriptor["params"].as_object();
    let names = |key| {
        params
            .and_then(|params| params.get(key))
            .and_then(Value::as_object)
            .map(|values| values.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    SearchResult {
        name: name.to_owned(),
        class: descriptor["class"].as_str().unwrap_or("unknown").to_owned(),
        target: descriptor["target"].as_str().unwrap_or("unknown").to_owned(),
        selectors: names("selectors"),
        fields: names("fields"),
        result: type_name(&descriptor["result"]),
    }
}

fn type_name(value: &Value) -> String {
    match value.get("name").and_then(Value::as_str) {
        Some(name) => name.to_owned(),
        None => value["kind"].as_str().unwrap_or("value").to_owned(),
    }
}

pub(super) fn has_scope_operations(scope: &str) -> bool {
    let target = catalog_target(scope);
    catalog()["operations"].as_object().is_some_and(|operations| {
        operations.values().any(|descriptor| descriptor["target"] == target)
    })
}

pub(super) fn scope_help(scope: &str) -> String {
    let target = catalog_target(scope);
    let operations = catalog()["operations"]
        .as_object()
        .expect("catalog operations object")
        .iter()
        .filter(|(_, descriptor)| descriptor["target"] == target)
        .map(|(name, descriptor)| (name, descriptor["class"].as_str().unwrap_or("unknown")))
        .collect::<Vec<_>>();
    let mut output = String::from("CATALOG OPERATIONS\n");
    for (name, class) in operations {
        output.push_str("  ");
        output.push_str(name);
        output.push_str(" [");
        output.push_str(class);
        output.push_str("]\n");
    }
    output.push_str("\nRun `cmux docs search <term>` for parameter and result details.\n");
    output
}

fn catalog_target(scope: &str) -> &str {
    match scope {
        "sidebar" => "sidebar_view",
        "pairing" => "pairing_request",
        "projection" => "frontend_projection",
        other => other,
    }
}

#[cfg(test)]
#[path = "docs_tests.rs"]
mod tests;
