//! Feed history and terminal UI. The default UI is the existing bundled
//! OpenTUI application; the dependency-free fallback is implemented in Rust.
use super::{integer, nonempty_env, parse_positive, rows, text};
use crate::{CliError, Context, Result, args};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::env;
use std::fs;
use std::io::{self, BufRead, IsTerminal, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

const OPENTUI_VERSION: &str = "0.1.106";
const OPENTUI_SOURCE: &str = include_str!("../../../../../Resources/feed-tui/index.ts");
static TERMINATED: AtomicI32 = AtomicI32::new(0);

pub(super) fn run(ctx: &Context, input: &[String]) -> Result<i32> {
    let sub = input.first().map(String::as_str).unwrap_or("help");
    let mut args = input.get(1..).unwrap_or(&[]).to_vec();
    match sub {
        "help" | "--help" | "-h" => ctx.print(super::usage("feed"))?,
        "clear" => {
            let yes = args::take_flag(&mut args, "--yes") | args::take_flag(&mut args, "-y");
            args::reject_remaining(&args, "feed clear")?;
            clear(ctx, yes)?;
        }
        "history" => {
            let limit = args::take_option(&mut args, "--limit")?
                .map(|s| parse_positive(&s, "--limit"))
                .transpose()?
                .unwrap_or(100) as usize;
            args::reject_remaining(&args, "feed history")?;
            history(ctx, limit)?;
        }
        "tui" => {
            let legacy = args::take_flag(&mut args, "--legacy");
            let opentui = args::take_flag(&mut args, "--opentui");
            if legacy && opentui {
                return Err(CliError::usage(
                    "cmux feed tui: choose only one TUI implementation",
                ));
            }
            args::reject_remaining(&args, "cmux feed tui")?;
            if ctx.non_interactive
                || ctx.json
                || ctx.envelope
                || !io::stdin().is_terminal()
                || !io::stdout().is_terminal()
            {
                return Err(CliError::new(
                    "interactive_required",
                    "cmux feed tui requires an interactive terminal",
                )
                .next("cmux feed history --json"));
            }
            if ctx.dry_run {
                ctx.emit(&json!({"command":"feed tui","would_open":true}))?;
                return Ok(0);
            }
            if legacy || env::var("CMUX_FEED_TUI_LEGACY").ok().as_deref() == Some("1") {
                return legacy_tui(ctx);
            }
            match open_tui(ctx) {
                Ok(code) => return Ok(code),
                Err(error) if !opentui => {
                    eprintln!(
                        "cmux feed tui: OpenTUI unavailable ({}); falling back to legacy TUI.",
                        error.message
                    );
                    return legacy_tui(ctx);
                }
                Err(error) => return Err(error),
            }
        }
        _ => return Err(CliError::usage(format!("Unknown feed subcommand: {sub}"))),
    }
    Ok(0)
}

fn home() -> Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| CliError::new("config", "HOME is unavailable"))
}
fn history_path() -> Result<PathBuf> {
    Ok(home()?.join(".cmuxterm/workstream.jsonl"))
}
fn clear(ctx: &Context, yes: bool) -> Result<()> {
    let path = history_path()?;
    if !path.exists() {
        if ctx.json || ctx.envelope {
            return ctx.emit(&json!({"path":path,"cleared":false}));
        }
        return ctx.print(format!(
            "No Feed history to clear ({} does not exist).",
            path.display()
        ));
    }
    if ctx.dry_run {
        return ctx.emit(&json!({"path":path,"would_clear":true}));
    }
    if !yes {
        if ctx.non_interactive || ctx.json || ctx.envelope || !io::stdin().is_terminal() {
            return Err(
                CliError::usage("feed clear requires --yes in non-interactive mode")
                    .next("cmux feed clear --yes"),
            );
        }
        print!(
            "This will permanently delete {}. Proceed? [y/N] ",
            path.display()
        );
        io::stdout().flush()?;
        let mut answer = String::new();
        io::stdin().read_line(&mut answer)?;
        if !answer.to_lowercase().starts_with('y') {
            return ctx.print("Aborted.");
        }
    }
    fs::remove_file(&path)?;
    if ctx.json || ctx.envelope {
        ctx.emit(&json!({"path":path,"cleared":true}))
    } else {
        ctx.print(format!("Cleared {}", path.display()))
    }
}
fn history(ctx: &Context, limit: usize) -> Result<()> {
    let path = history_path()?;
    let file = match fs::File::open(&path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return ctx.emit(&json!({"path":path,"items":[]}));
        }
        Err(e) => return Err(e.into()),
    };
    let mut lines = std::collections::VecDeque::with_capacity(limit.min(1024));
    for line in io::BufReader::new(file).lines() {
        let line = line?;
        if line.len() > 16 * 1024 * 1024 {
            return Err(CliError::new(
                "history_too_large",
                "Feed history contains an oversized entry",
            ));
        }
        if lines.len() == limit {
            lines.pop_front();
        }
        lines.push_back(line);
    }
    if ctx.json || ctx.envelope {
        let items: Vec<Value> = lines
            .iter()
            .map(|line| serde_json::from_str(line).unwrap_or_else(|_| json!({"raw":line})))
            .collect();
        ctx.emit(&json!({"path":path,"items":items}))
    } else {
        for line in lines {
            ctx.print(line)?;
        }
        Ok(())
    }
}
fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
fn bun() -> Result<PathBuf> {
    let mut paths = Vec::new();
    if let Some(path) = nonempty_env("CMUX_FEED_TUI_BUN_PATH") {
        paths.push(PathBuf::from(path));
    }
    if let Some(path) = env::var_os("PATH") {
        paths.extend(env::split_paths(&path).map(|p| p.join("bun")));
    }
    if let Ok(home) = home() {
        paths.push(home.join(".bun/bin/bun"));
        paths.push(home.join(".local/bin/bun"));
    }
    paths.extend([
        PathBuf::from("/opt/homebrew/bin/bun"),
        PathBuf::from("/usr/local/bin/bun"),
    ]);
    paths
        .into_iter()
        .find(|p| is_executable(p))
        .ok_or_else(|| CliError::new("dependency_missing", "Bun is required for the OpenTUI Feed"))
}
fn write_changed(path: &Path, content: &str) -> Result<()> {
    if fs::read_to_string(path).ok().as_deref() == Some(content) {
        return Ok(());
    }
    let temp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;
    fs::rename(temp, path)?;
    Ok(())
}
fn prepare_app(bun: &Path) -> Result<PathBuf> {
    let dir = home()?.join(".cmuxterm/feed-tui-opentui");
    fs::create_dir_all(&dir)?;
    // Concurrent invocations must not interleave the package/source upgrade
    // and dependency installation in the user's shared cache.
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join(".prepare.lock"))?;
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    write_changed(
        &dir.join("package.json"),
        &format!(
            "{{\"private\":true,\"type\":\"module\",\"dependencies\":{{\"@opentui/core\":\"{OPENTUI_VERSION}\"}}}}\n"
        ),
    )?;
    write_changed(&dir.join("index.ts"), OPENTUI_SOURCE)?;
    let installed = fs::read(dir.join("node_modules/@opentui/core/package.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
    if installed.as_ref().and_then(|v| v["version"].as_str()) != Some(OPENTUI_VERSION) {
        eprintln!("cmux feed tui: installing @opentui/core {OPENTUI_VERSION}...");
        let output = Command::new(bun)
            .args(["install", "--silent"])
            .current_dir(&dir)
            .stdin(Stdio::null())
            .output()?;
        if !output.status.success() {
            return Err(CliError::new(
                "dependency_install",
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            )
            .next("cmux feed tui --legacy"));
        }
    }
    Ok(dir)
}
fn open_tui(ctx: &Context) -> Result<i32> {
    let bun = bun()?;
    eprintln!("cmux feed tui: preparing OpenTUI Feed...");
    let dir = prepare_app(&bun)?;
    let socket = crate::transport::resolved_socket_path(ctx)?;
    let password = crate::transport::resolved_password(ctx, &socket);
    eprintln!("cmux feed tui: starting OpenTUI Feed.");
    let mut command = Command::new(bun);
    command
        .arg(dir.join("index.ts"))
        .env_remove("CMUX_SOCKET")
        .env("CMUX_SOCKET_PATH", socket)
        .env("OTUI_USE_ALTERNATE_SCREEN", "1")
        .env("CMUX_FEED_TUI_PATH", "opentui");
    if env::var_os("OTUI_USE_CONSOLE").is_none() {
        command.env("OTUI_USE_CONSOLE", "0");
    }
    if let Some(password) = password? {
        command.env("CMUX_SOCKET_PASSWORD", password);
    } else {
        command.env_remove("CMUX_SOCKET_PASSWORD");
    }
    let status = command.status()?;
    use std::os::unix::process::ExitStatusExt;
    if status.success() || status.code() == Some(130) || status.signal() == Some(libc::SIGINT) {
        Ok(0)
    } else {
        Err(CliError::new(
            "feed_exited",
            format!(
                "OpenTUI Feed exited with status {}",
                status.code().unwrap_or(1)
            ),
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Key {
    Tick,
    Up,
    Down,
    Enter,
    Quit,
    Refresh,
    Deny,
    Feedback,
    Once,
    Always,
    All,
    Bypass,
    Manual,
    Ultraplan,
    Number(usize),
    Ignored,
}
extern "C" fn signal_handler(signal: i32) {
    TERMINATED.store(signal, Ordering::SeqCst);
}
struct Terminal {
    original: libc::termios,
    signals: Vec<(i32, libc::sighandler_t)>,
}
impl Terminal {
    fn enter() -> Result<Self> {
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut terminal = Self {
            original,
            signals: Vec::new(),
        };
        terminal.raw()?;
        TERMINATED.store(0, Ordering::SeqCst);
        for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
            terminal.signals.push((signal, unsafe {
                libc::signal(signal, signal_handler as *const () as libc::sighandler_t)
            }));
        }
        print!("\x1b[?1049h\x1b[?25l");
        io::stdout().flush()?;
        Ok(terminal)
    }
    fn raw(&self) -> Result<()> {
        let mut raw = self.original;
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        Ok(())
    }
    fn restore(&self) {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &self.original) };
    }
    fn prompt(&self) -> Result<String> {
        self.restore();
        print!("\x1b[2J\x1b[HTell the agent what to change, then press Return.\n> ");
        io::stdout().flush()?;
        let mut text = String::new();
        let result = io::stdin().read_line(&mut text);
        self.raw()?;
        result?;
        Ok(text.trim().to_owned())
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        self.restore();
        for (signal, handler) in &self.signals {
            unsafe { libc::signal(*signal, *handler) };
        }
        let _ = write!(io::stdout(), "\x1b[?25h\x1b[?1049l");
        let _ = io::stdout().flush();
    }
}
fn read_byte(timeout: i32) -> Option<u8> {
    let mut descriptor = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
        revents: 0,
    };
    let n = unsafe { libc::poll(&mut descriptor, 1, timeout) };
    if n <= 0 {
        return None;
    }
    if descriptor.revents & libc::POLLHUP != 0 {
        return Some(b'q');
    }
    let mut byte = 0u8;
    if unsafe { libc::read(libc::STDIN_FILENO, (&mut byte as *mut u8).cast(), 1) } == 1 {
        Some(byte)
    } else {
        Some(b'q')
    }
}
fn key() -> Key {
    match read_byte(1000) {
        None => Key::Tick,
        Some(byte) => match byte {
            3 | b'q' | b'Q' => Key::Quit,
            10 | 13 => Key::Enter,
            b'j' | b'J' => Key::Down,
            b'k' | b'K' => Key::Up,
            b'r' | b'R' => Key::Refresh,
            b'd' | b'D' => Key::Deny,
            b'f' | b'F' => Key::Feedback,
            b'o' | b'O' => Key::Once,
            b'a' | b'A' => Key::Always,
            b'l' | b'L' => Key::All,
            b'b' | b'B' => Key::Bypass,
            b'm' | b'M' => Key::Manual,
            b'u' | b'U' => Key::Ultraplan,
            b'1'..=b'9' => Key::Number((byte - b'0') as usize),
            b'0' => Key::Number(10),
            27 => {
                if read_byte(25) == Some(b'[') {
                    match read_byte(25) {
                        Some(b'A') => Key::Up,
                        Some(b'B') => Key::Down,
                        _ => Key::Ignored,
                    }
                } else {
                    Key::Ignored
                }
            }
            _ => Key::Ignored,
        },
    }
}
fn size() -> (usize, usize) {
    let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
    if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0
        && size.ws_col > 0
        && size.ws_row > 0
    {
        (size.ws_col as usize, size.ws_row as usize)
    } else {
        (80, 24)
    }
}
fn line(raw: &str, width: usize) -> String {
    let text: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let mut chars = text.chars();
    let mut out: String = chars.by_ref().take(width).collect();
    if chars.next().is_some() && width > 3 {
        out = out.chars().take(width - 3).collect();
        out.push_str("...");
    }
    out
}
fn detail(item: &Value) -> &str {
    match text(item, "kind", "") {
        "permissionRequest" => text(item, "tool_input", ""),
        "exitPlan" => item["plan_summary"]
            .as_str()
            .or_else(|| item["plan"].as_str())
            .unwrap_or("Review the proposed plan"),
        "question" => text(item, "question_prompt", "Answer the agent question"),
        _ => text(item, "text", ""),
    }
}
fn render(items: &[Value], selected: usize, status: &str) -> Result<()> {
    let (width, height) = size();
    let visible = (height.saturating_sub(5) / 5).max(1);
    let start = selected.saturating_sub(visible - 1);
    let end = (start + visible).min(items.len());
    print!(
        "\x1b[2J\x1b[H{}\r\n{}\r\n{}\r\n",
        line(
            &format!(
                "cmux Dock Feed  latest first  {} pending  {} total  {}-{end}",
                items.len(),
                items.len(),
                if items.is_empty() { 0 } else { start + 1 }
            ),
            width
        ),
        line(
            "j/k arrows move  enter default  d deny  f replan  r refresh  q quit",
            width
        ),
        "-".repeat(width)
    );
    for (index, item) in items.iter().enumerate().take(end).skip(start) {
        let selected = index == selected;
        let prefix = if selected { "\x1b[7m" } else { "" };
        let suffix = if selected { "\x1b[0m" } else { "" };
        for content in [
            format!(
                "{} [PENDING] @{}  {}",
                if selected { ">" } else { " " },
                text(item, "source", ""),
                text(item, "kind", "")
            ),
            format!("  {}", text(item, "title", text(item, "kind", ""))),
            format!("  {}", detail(item)),
            String::new(),
        ] {
            print!("{prefix}{}{suffix}\r\n", line(&content, width));
        }
        print!("{}\r\n", "-".repeat(width));
    }
    if items.is_empty() {
        print!("No feed items yet.\r\n");
    }
    print!(
        "\x1b[{};1H{}\x1b[{height};1H{}",
        height.saturating_sub(1).max(1),
        "-".repeat(width),
        line(
            if status.is_empty() {
                "o once  a always  l all  b bypass  m manual  u ultraplan  1-0 answer"
            } else {
                status
            },
            width
        )
    );
    io::stdout().flush()?;
    Ok(())
}
fn ready() {
    if let Some(path) = nonempty_env("CMUX_FEED_TUI_READY_PATH") {
        let path = PathBuf::from(path);
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _=fs::write(path,json!({"stage":"legacy-ready","pid":std::process::id().to_string(),"time":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64().to_string()}).to_string());
    }
}
fn legacy_tui(ctx: &Context) -> Result<i32> {
    let terminal = Terminal::enter()?;
    let mut selected = 0usize;
    let mut selected_id = String::new();
    let mut selected_options: HashMap<String, BTreeSet<String>> = HashMap::new();
    let mut status = String::new();
    let mut marked = false;
    loop {
        let signal = TERMINATED.load(Ordering::SeqCst);
        if signal != 0 {
            return Ok(128 + signal);
        }
        let payload = ctx.rpc("feed.list", json!({"pending_only":true}))?;
        let mut items: Vec<Value> = rows(&payload, "items")
            .iter()
            .filter(|v| {
                v["status"] == "pending"
                    && v["request_id"].is_string()
                    && matches!(
                        v["kind"].as_str(),
                        Some("permissionRequest" | "exitPlan" | "question")
                    )
            })
            .cloned()
            .collect();
        items.sort_by(|a, b| {
            text(b, "created_at", "")
                .cmp(text(a, "created_at", ""))
                .then(text(b, "id", "").cmp(text(a, "id", "")))
        });
        if let Some(index) = items.iter().position(|v| text(v, "id", "") == selected_id) {
            selected = index;
        }
        selected = selected.min(items.len().saturating_sub(1));
        render(&items, selected, &status)?;
        if !marked {
            ready();
            marked = true;
        }
        status.clear();
        match key() {
            Key::Quit => return Ok(0),
            Key::Up => selected = selected.saturating_sub(1),
            Key::Down => selected = (selected + 1).min(items.len().saturating_sub(1)),
            Key::Tick | Key::Refresh | Key::Ignored => {}
            key => {
                if let Some(item) = items.get(selected) {
                    status = resolve(ctx, item, key, &terminal, &mut selected_options)?;
                }
            }
        }
        selected_id = items
            .get(selected)
            .map(|v| text(v, "id", "").to_owned())
            .unwrap_or_default();
    }
}
fn permission_capabilities(item: &Value) -> (bool, bool, bool, bool) {
    let source = text(item, "source", "");
    let bypass = !matches!(source, "codex" | "claude" | "hermes-agent");
    if source == "hermes-agent" {
        return (true, false, false, false);
    }
    if source != "codex" {
        return (true, true, true, bypass);
    }
    let raw = item["tool_input_capabilities"]
        .as_str()
        .or_else(|| item["tool_input"].as_str())
        .unwrap_or("");
    let Ok(object) = serde_json::from_str::<Value>(raw) else {
        return (false, false, false, false);
    };
    let decisions = object
        .get("available_decisions")
        .or_else(|| object.get("availableDecisions"));
    let available = |name: &str| {
        decisions.is_none_or(|d| {
            d.as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|v| v.as_str() == Some(name) || v.get(name).is_some())
            })
        })
    };
    let method = text(&object, "app_server_method", "");
    if method == "item/permissions/requestApproval" {
        return (true, true, true, false);
    }
    let all = method == "item/commandExecution/requestApproval"
        && ((object
            .get("proposed_execpolicy_amendment")
            .is_some_and(|v| !v.is_null())
            && available("acceptWithExecpolicyAmendment"))
            || (!rows(&object, "proposed_network_policy_amendments").is_empty()
                && available("applyNetworkPolicyAmendment")));
    (
        available("accept"),
        available("acceptForSession"),
        all,
        false,
    )
}
fn resolve(
    ctx: &Context,
    item: &Value,
    key: Key,
    terminal: &Terminal,
    selections: &mut HashMap<String, BTreeSet<String>>,
) -> Result<String> {
    let request = text(item, "request_id", "");
    let capabilities = permission_capabilities(item);
    match text(item, "kind", "") {
        "permissionRequest" => {
            let mode = match key {
                Key::Enter | Key::Once if capabilities.0 => "once",
                Key::Always if capabilities.1 => "always",
                Key::All if capabilities.2 => "all",
                Key::Bypass if capabilities.3 => "bypass",
                Key::Deny => "deny",
                _ => return Ok("Key is not available for permission requests".into()),
            };
            ctx.rpc(
                "feed.permission.reply",
                json!({"request_id":request,"mode":mode}),
            )?;
            Ok(format!("Permission {mode} sent"))
        }
        "exitPlan" => {
            let mode = match key {
                Key::Enter => text(item, "default_mode", "manual"),
                Key::Always => "autoAccept",
                Key::Manual => "manual",
                Key::Ultraplan => "ultraplan",
                Key::Bypass if capabilities.3 => "bypassPermissions",
                Key::Deny | Key::Feedback => "deny",
                _ => return Ok("Key is not available for plans".into()),
            };
            let mut params = json!({"request_id":request,"mode":mode});
            if key == Key::Feedback {
                let feedback = terminal.prompt()?;
                if feedback.is_empty() {
                    return Ok("Replan cancelled".into());
                }
                params["feedback"] = json!(feedback);
            }
            ctx.rpc("feed.exit_plan.reply", params)?;
            Ok(format!("Plan {mode} sent"))
        }
        "question" => {
            let questions = rows(item, "questions");
            let first = questions.first();
            let options = first
                .map(|v| rows(v, "options"))
                .unwrap_or_else(|| rows(item, "question_options"));
            if questions.len() > 1 && key == Key::Enter {
                let answers: Vec<&str> = questions
                    .iter()
                    .map(|q| {
                        rows(q, "options")
                            .first()
                            .map(|v| text(v, "label", ""))
                            .unwrap_or("")
                    })
                    .collect();
                ctx.rpc(
                    "feed.question.reply",
                    json!({"request_id":request,"selections":answers}),
                )?;
                return Ok("Question answer sent".into());
            }
            let multiple = first
                .and_then(|v| v.get("multi_select").or_else(|| v.get("multiSelect")))
                .or_else(|| item.get("question_multi_select"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let chosen = selections.entry(request.to_owned()).or_default();
            let answers: Vec<String> = if multiple {
                match key {
                    Key::Number(index) => {
                        if let Some(option) = options.get(index - 1) {
                            let id = text(option, "id", "").to_owned();
                            if !chosen.remove(&id) {
                                chosen.insert(id);
                            }
                            return Ok(format!("Selected: {}", text(option, "label", "")));
                        }
                        return Ok(format!("No option {index}"));
                    }
                    Key::Enter => options
                        .iter()
                        .filter(|v| chosen.contains(text(v, "id", "")))
                        .map(|v| text(v, "label", "").to_owned())
                        .collect(),
                    _ => return Ok("Key is not available for questions".into()),
                }
            } else {
                match key {
                    Key::Enter => options
                        .first()
                        .map(|v| vec![text(v, "label", "").to_owned()])
                        .unwrap_or_default(),
                    Key::Number(index) => {
                        if let Some(option) = options.get(index - 1) {
                            vec![text(option, "label", "").to_owned()]
                        } else {
                            return Ok(format!("No option {index}"));
                        }
                    }
                    _ => return Ok("Key is not available for questions".into()),
                }
            };
            ctx.rpc(
                "feed.question.reply",
                json!({"request_id":request,"selections":answers}),
            )?;
            selections.remove(request);
            Ok("Question answer sent".into())
        }
        _ => Ok("Unsupported feed item".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_capabilities_fail_closed() {
        assert_eq!(
            permission_capabilities(&json!({"source":"codex","tool_input":"broken"})),
            (false, false, false, false)
        );
    }
    #[test]
    fn codex_decision_allowlist_is_respected() {
        let input=json!({"app_server_method":"item/commandExecution/requestApproval","available_decisions":["acceptForSession"]}).to_string();
        assert_eq!(
            permission_capabilities(&json!({"source":"codex","tool_input":input})),
            (false, true, false, false)
        );
    }
    #[test]
    fn terminal_controls_are_sanitized() {
        assert_eq!(line("a\x1b\r\nb", 10), "a   b");
        assert_eq!(line("abcdef", 4), "a...");
    }
}
