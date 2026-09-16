//! File, markdown, diff, feedback, and session restore commands.
//!
//! The macOS app owns pane creation and the diff/markdown renderer.  The Rust
//! CLI owns validation, path resolution, git input and stable output.
use crate::{CliError, Context, Result, args};
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::Command;

const OPEN_USAGE: &str = "cmux open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus]";
const DIFF_USAGE: &str = "cmux diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--session <id>] [--cwd <path>] [--base <ref>] [--focus true|false] [--no-focus] [--title <text>] [--layout split|unified] [--font-size <points>]";

pub fn run(ctx: &Context, command: &str, input: &[String]) -> Result<Option<i32>> {
    match command {
        "open" => open(ctx, input).map(Some),
        "diff" => diff(ctx, input).map(Some),
        "markdown" => markdown(ctx, input).map(Some),
        "feedback" => feedback(ctx, input).map(Some),
        "restore-session" => restore_session(ctx, input).map(Some),
        value
            if input.is_empty()
                && is_path_or_url(value)
                && (Path::new(value).exists() || is_http_url(value)) =>
        {
            if !is_http_url(value) {
                open_path_without_socket(value).map(Some)
            } else {
                open(ctx, &[value.to_owned()]).map(Some)
            }
        }
        _ => Ok(None),
    }
}

fn open_path_without_socket(raw: &str) -> Result<i32> {
    let resolved = PathBuf::from(resolve_path(raw));
    let metadata = fs::metadata(&resolved).map_err(|_| {
        CliError::new(
            "path.missing",
            format!("Path does not exist: {}", resolved.display()),
        )
    })?;
    let directory = if metadata.is_dir() {
        resolved
    } else {
        resolved
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| CliError::new("path.invalid", "Path has no parent directory"))?
    };
    let app = env::var("CMUX_APP_PATH").unwrap_or_else(|_| {
        std::env::current_exe()
            .ok()
            .and_then(|path| {
                path.ancestors()
                    .find(|candidate| candidate.extension().and_then(|v| v.to_str()) == Some("app"))
                    .map(|candidate| candidate.to_string_lossy().into_owned())
            })
            .unwrap_or_else(|| "cmux".into())
    });
    let mut command = Command::new("/usr/bin/open");
    command.arg("-a").arg(&app).arg(directory.as_os_str());
    let mut scrubbed = env::vars().collect::<std::collections::HashMap<_, _>>();
    for key in [
        "CMUX_SOCKET",
        "CMUX_SOCKET_PATH",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_PANEL_ID",
    ] {
        scrubbed.remove(key);
    }
    command.env_clear().envs(scrubbed);
    let status = command
        .status()
        .map_err(|e| CliError::new("app.open", format!("Failed to open path in cmux: {e}")))?;
    if !status.success() {
        return Err(CliError::new(
            "app.open",
            format!("Failed to open {} in cmux", directory.display()),
        ));
    }
    println!("OK");
    Ok(0)
}

#[derive(Default)]
struct Routing {
    workspace: Option<String>,
    window: Option<String>,
    surface: Option<String>,
    pane: Option<String>,
    focus: Option<bool>,
}

fn routing(ctx: &Context, args: &mut Vec<String>, allow_pane: bool) -> Result<Routing> {
    let mut out = Routing::default();
    out.workspace = args::take_option(args, "--workspace")?;
    out.window = args::take_option(args, "--window")?;
    out.surface = args::take_option(args, "--surface")?;
    if allow_pane {
        out.pane = args::take_option(args, "--pane")?;
    }
    if args::take_flag(args, "--no-focus") {
        out.focus = Some(false);
    }
    if let Some(raw) = args::take_option(args, "--focus")? {
        if out.focus.is_some() {
            return Err(CliError::usage("--focus and --no-focus cannot be combined"));
        }
        out.focus = Some(
            args::parse_bool(&raw).map_err(|_| CliError::usage("--focus must be true|false"))?,
        );
    }
    if out.window.is_none() {
        out.window = ctx.window.clone();
    }
    let window = ctx.resolve_id("window", out.window.as_deref())?;
    let workspace_value = out.workspace.clone().or_else(|| {
        if out.window.is_none() {
            env::var("CMUX_WORKSPACE_ID").ok()
        } else {
            None
        }
    });
    let workspace = ctx.resolve_id("workspace", workspace_value.as_deref())?;
    let surface_value = out.surface.clone().or_else(|| {
        if out.window.is_none() && out.pane.is_none() {
            env::var("CMUX_SURFACE_ID").ok()
        } else {
            None
        }
    });
    let surface = ctx.resolve_id("surface", surface_value.as_deref())?;
    let pane = ctx.resolve_id("pane", out.pane.as_deref())?;
    out.window = window;
    out.workspace = workspace;
    out.surface = surface;
    out.pane = pane;
    Ok(out)
}

fn open(ctx: &Context, input: &[String]) -> Result<i32> {
    let mut args = input.to_vec();
    let route = routing(ctx, &mut args, true)?;
    let mut targets = Vec::new();
    let mut parsing = true;
    for arg in args {
        if parsing && arg == "--" {
            parsing = false;
            continue;
        }
        if parsing && arg.starts_with('-') {
            return Err(CliError::usage(format!(
                "open: unknown flag '{arg}'. Usage: {OPEN_USAGE}"
            )));
        }
        targets.push(classify_open_target(&arg)?);
    }
    if targets.is_empty() {
        return Err(CliError::usage(format!(
            "open requires at least one path or URL. Usage: {OPEN_USAGE}"
        )));
    }
    let mut opened = Vec::new();
    let mut files = Vec::new();
    let focus = route.focus.unwrap_or(true);
    for target in targets {
        match target {
            OpenTarget::File(path) => files.push(path),
            OpenTarget::Directory(path) => {
                flush_files(ctx, &route, &mut files, &mut opened, focus)?;
                let payload = ctx.rpc(
                    "workspace.create",
                    json!({"cwd":path.clone(),"window_id":route.window.as_deref()}),
                )?;
                opened.push(json!({"kind":"workspace","payload":payload,"path":path}));
            }
            OpenTarget::Url(url, default_focus) => {
                flush_files(ctx, &route, &mut files, &mut opened, focus)?;
                let mut params =
                    json!({"url":url.clone(),"focus":route.focus.unwrap_or(default_focus)});
                route_params_without_pane(&mut params, &route);
                let payload = ctx.rpc("browser.open_split", params)?;
                opened.push(json!({"kind":"url","payload":payload,"url":url}));
            }
        }
    }
    flush_files(ctx, &route, &mut files, &mut opened, focus)?;
    if ctx.json || ctx.envelope {
        ctx.emit(&json!({"opened":opened}))?;
    } else {
        ctx.print(format!("OK opened={}", opened.len()))?;
    }
    Ok(0)
}
fn flush_files(
    ctx: &Context,
    route: &Routing,
    files: &mut Vec<String>,
    opened: &mut Vec<Value>,
    focus: bool,
) -> Result<()> {
    if files.is_empty() {
        return Ok(());
    }
    let mut params = json!({"paths":files,"focus":focus});
    route_params(&mut params, route);
    let payload = ctx.rpc("file.open", params)?;
    opened.push(json!({"kind":"file","payload":payload}));
    files.clear();
    Ok(())
}
fn route_params(params: &mut Value, route: &Routing) {
    route_params_without_pane(params, route);
    if let Some(v) = &route.pane {
        params["pane_id"] = json!(v);
    }
}
fn route_params_without_pane(params: &mut Value, route: &Routing) {
    if let Some(v) = &route.window {
        params["window_id"] = json!(v);
    }
    if let Some(v) = &route.workspace {
        params["workspace_id"] = json!(v);
    }
    if let Some(v) = &route.surface {
        params["surface_id"] = json!(v);
    }
}

enum OpenTarget {
    File(String),
    Directory(String),
    Url(String, bool),
}
fn classify_open_target(raw: &str) -> Result<OpenTarget> {
    if is_http_url(raw) {
        return Ok(OpenTarget::Url(raw.to_owned(), true));
    }
    let path = resolve_path(raw);
    let metadata = fs::metadata(&path)
        .map_err(|_| CliError::new("path.missing", format!("Path does not exist: {path}")))?;
    if metadata.is_dir() {
        return Ok(OpenTarget::Directory(path));
    }
    if matches!(
        Path::new(&path)
            .extension()
            .and_then(|x| x.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("html" | "htm")
    ) {
        return Ok(OpenTarget::Url(file_url(Path::new(&path)), false));
    }
    Ok(OpenTarget::File(path))
}

fn markdown(ctx: &Context, input: &[String]) -> Result<i32> {
    let mut args = input.to_vec();
    let route = routing(ctx, &mut args, false)?;
    let direction = args::take_option(&mut args, "--direction")?.unwrap_or_else(|| "right".into());
    if !matches!(direction.as_str(), "right" | "down" | "left" | "up") {
        return Err(CliError::usage("--direction must be right|down|left|up"));
    }
    let size = args::take_option(&mut args, "--font-size")?
        .map(|v| {
            parse_range(
                &v,
                8.0,
                96.0,
                "--font-size must be a number between 8 and 96",
            )
        })
        .transpose()?;
    if args
        .first()
        .map(|v| v.eq_ignore_ascii_case("open"))
        .unwrap_or(false)
    {
        args.remove(0);
    }
    let raw = args.first().ok_or_else(|| {
        CliError::usage("markdown open requires a file path. Usage: cmux markdown open <path>")
    })?;
    if args.len() > 1 {
        return Err(CliError::usage(format!(
            "markdown open: unexpected argument '{}'",
            args[1]
        )));
    }
    let path = resolve_path(raw);
    let metadata = fs::metadata(&path)
        .map_err(|_| CliError::new("path.missing", format!("Path does not exist: {path}")))?;
    if !metadata.is_file() {
        return Err(CliError::new(
            "path.invalid",
            format!("Path is not a file: {path}"),
        ));
    }
    let mut params = json!({"path":path.clone(),"direction":direction.clone(),"focus":route.focus.unwrap_or(false)});
    if let Some(v) = size {
        params["font_size"] = json!(v);
    }
    route_params_without_pane(&mut params, &route);
    let payload = ctx.rpc("markdown.open", params)?;
    if ctx.json || ctx.envelope {
        ctx.emit(&payload)?;
    } else {
        ctx.print(format!(
            "OK surface={} pane={} path={path}",
            payload["surface_id"].as_str().unwrap_or("unknown"),
            payload["pane_id"].as_str().unwrap_or("unknown")
        ))?;
    }
    Ok(0)
}

fn feedback(ctx: &Context, input: &[String]) -> Result<i32> {
    let mut args = input.to_vec();
    let email = args::take_option(&mut args, "--email")?;
    let body = args::take_option(&mut args, "--body")?;
    let mut images = Vec::new();
    while let Some(v) = args::take_option(&mut args, "--image")? {
        images.push(resolve_path(&v));
    }
    args.retain(|v| v != "--");
    if let Some(v) = args.first() {
        return Err(CliError::usage(format!(
            "feedback: unknown flag '{v}'. Known flags: --email <email>, --body <text>, --image <path>"
        )));
    }
    let payload = if email.is_none() && body.is_none() && images.is_empty() {
        if let Ok(ws) = env::var("CMUX_WORKSPACE_ID") {
            ctx.rpc("feedback.open", json!({"workspace_id":ws,"activate":false}))?
        } else {
            ctx.rpc("feedback.open", json!({"activate":true}))?
        }
    } else {
        let email = email.filter(|v| !v.trim().is_empty()).ok_or_else(|| {
            CliError::usage("feedback requires --email <email> when sending feedback")
        })?;
        let body = body.filter(|v| !v.trim().is_empty()).ok_or_else(|| {
            CliError::usage("feedback requires --body <text> when sending feedback")
        })?;
        ctx.rpc(
            "feedback.submit",
            json!({"email":email,"body":body,"image_paths":images}),
        )?
    };
    if ctx.json || ctx.envelope {
        ctx.emit(&payload)?;
    } else {
        ctx.print("OK")?;
    }
    Ok(0)
}
fn restore_session(ctx: &Context, input: &[String]) -> Result<i32> {
    let args = input
        .iter()
        .filter(|v| v.as_str() != "--")
        .collect::<Vec<_>>();
    if let Some(v) = args.first() {
        return Err(CliError::usage(format!(
            "restore-session: unknown flag '{v}'"
        )));
    }
    let payload = ctx.rpc("session.restore_previous", json!({}))?;
    if ctx.json || ctx.envelope {
        ctx.emit(&payload)?;
    } else {
        ctx.print("OK")?;
    }
    Ok(0)
}

fn diff(ctx: &Context, input: &[String]) -> Result<i32> {
    let mut args = input.to_vec();
    let route = routing(ctx, &mut args, false)?;
    let title = args::take_option(&mut args, "--title")?.unwrap_or_else(|| "cmux diff".into());
    let layout = args::take_option(&mut args, "--layout")?.unwrap_or_else(|| "unified".into());
    if !matches!(layout.as_str(), "split" | "unified") {
        return Err(CliError::usage("--layout must be split|unified"));
    }
    let size = args::take_option(&mut args, "--font-size")?
        .map(|v| {
            parse_range(
                &v,
                1.0,
                96.0,
                "--font-size must be a positive number no larger than 96",
            )
        })
        .transpose()?;
    let cwd = args::take_option(&mut args, "--cwd")?
        .or_else(|| args::take_option(&mut args, "--repo").ok().flatten())
        .unwrap_or_else(|| {
            env::current_dir()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        });
    let base = args::take_option(&mut args, "--base")?
        .or_else(|| args::take_option(&mut args, "--branch-base").ok().flatten());
    let session = args::take_option(&mut args, "--session")?.or_else(|| {
        args::take_option(&mut args, "--agent-session")
            .ok()
            .flatten()
    });
    let mut source_values = Vec::new();
    if let Some(value) = args::take_option(&mut args, "--source")? {
        source_values.push(value);
    }
    for (flag, name) in [
        ("--unstaged", "unstaged"),
        ("--staged", "staged"),
        ("--branch", "branch"),
        ("--last-turn", "last-turn"),
    ] {
        if args::take_flag(&mut args, flag) {
            source_values.push(name.to_owned());
        }
    }
    if source_values.len() > 1 {
        return Err(CliError::usage("diff accepts only one source"));
    }
    let source = source_values.pop();
    if let Some(s) = &source {
        if !matches!(s.as_str(), "unstaged" | "staged" | "branch" | "last-turn") {
            return Err(CliError::usage(format!(
                "Unknown diff source '{s}'. Expected unstaged, staged, branch, or last-turn."
            )));
        }
    }
    if args.len() > 1 {
        return Err(CliError::usage(format!(
            "diff accepts at most one patch file. Usage: {DIFF_USAGE}"
        )));
    }
    if let Some(value) = args.first() {
        if value.starts_with('-') && value != "-" {
            return Err(CliError::usage(format!(
                "diff: unknown flag '{value}'. Usage: {DIFF_USAGE}"
            )));
        }
    }
    if source.is_some() && !args.is_empty() {
        return Err(CliError::usage(
            "diff accepts either a patch file or a git source, not both",
        ));
    }
    if source.as_deref() == Some("last-turn")
        && (route.workspace.is_none() || route.surface.is_none())
    {
        return Err(CliError::usage(
            "cmux diff --last-turn requires a workspace and surface context. Run it from a cmux terminal or pass --workspace and --surface.",
        ));
    }
    let patch = if let Some(s) = source.as_deref() {
        git_patch(s, &cwd, base.as_deref())?
    } else if let Some(path) = args.first() {
        read_patch(path)?
    } else {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text)?;
        if text.is_empty() && atty_stdin() {
            return Err(CliError::usage(format!(
                "diff requires a patch file, piped stdin, or a git source. Usage: {DIFF_USAGE}"
            )));
        }
        text
    };
    let viewer = write_diff_html(&title, &layout, size, &patch)?;
    let viewer_url = file_url(&viewer);
    let viewer_path = viewer.to_string_lossy().into_owned();
    let mut params = json!({"url":viewer_url.clone(),"focus":route.focus.unwrap_or(false),"show_omnibar":false,"transparent_background":true,"bypass_remote_proxy":true,"title":title.clone(),"diff_viewer_layout":layout.clone(),"diff_viewer_source":source.clone().unwrap_or_else(||"patch".into())});
    route_params_without_pane(&mut params, &route);
    if let Some(s) = session {
        params["session_id"] = json!(s);
    }
    let payload = ctx.rpc("browser.open_split", params)?;
    if ctx.json || ctx.envelope {
        let mut out = payload;
        if let Value::Object(m) = &mut out {
            m.insert("path".into(), json!(viewer_path));
            m.insert("url".into(), json!(viewer_url));
            m.insert("title".into(), json!(title));
            m.insert(
                "source".into(),
                json!(source.unwrap_or_else(|| "patch".into())),
            );
        }
        ctx.emit(&out)?;
    } else {
        ctx.print(format!(
            "OK surface={} pane={}",
            payload["surface_id"].as_str().unwrap_or("unknown"),
            payload["pane_id"].as_str().unwrap_or("unknown")
        ))?;
    }
    Ok(0)
}
fn git_patch(source: &str, cwd: &str, base: Option<&str>) -> Result<String> {
    let root = git(cwd, &["rev-parse", "--show-toplevel"])
        .map_err(|_| CliError::new("git.repo", format!("Not a git repository: {cwd}")))?
        .trim()
        .to_owned();
    let args: Vec<String> = match source {
        "unstaged" => vec!["diff".into(), "--".into()],
        "staged" => vec!["diff".into(), "--cached".into(), "--".into()],
        "branch" => {
            let b = base.unwrap_or("origin/main");
            let m = git(&root, &["merge-base", "HEAD", b])?;
            vec!["diff".into(), m.trim().into(), "--".into()]
        }
        "last-turn" => Vec::new(),
        _ => {
            return Err(CliError::usage(format!(
                "Unknown diff source '{source}'. Expected unstaged, staged, branch, or last-turn."
            )));
        }
    };
    if args.is_empty() {
        Ok(String::new())
    } else {
        git(&root, &args.iter().map(String::as_str).collect::<Vec<_>>())
    }
}
fn git(cwd: &str, args: &[&str]) -> Result<String> {
    let out = Command::new("git").args(["-C", cwd]).args(args).output()?;
    if !out.status.success() {
        return Err(CliError::new(
            "git.failed",
            String::from_utf8_lossy(&out.stderr).trim().to_owned(),
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
fn read_patch(raw: &str) -> Result<String> {
    if raw == "-" {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text)?;
        return Ok(text);
    }
    if is_http_url(raw) {
        let host = raw
            .split("//")
            .nth(1)
            .and_then(|value| value.split('/').next())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let trusted =
            matches!(
                host.as_str(),
                "github.com" | "www.github.com" | "diffshub.com" | "www.diffshub.com"
            ) && (raw.ends_with(".diff") || raw.ends_with(".patch") || raw.contains("/pull/"));
        if !trusted {
            return Err(CliError::new(
                "patch.url_untrusted",
                "Only GitHub pull-request .diff/.patch URLs are accepted as patch input",
            ));
        }
        let output = Command::new("curl")
            .args(["--fail", "--silent", "--show-error", "--location", raw])
            .output()
            .map_err(|e| CliError::new("patch.fetch", e.to_string()))?;
        if !output.status.success() {
            return Err(CliError::new(
                "patch.fetch",
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ));
        }
        return String::from_utf8(output.stdout)
            .map_err(|_| CliError::new("patch.read", "Patch URL was not UTF-8"));
    }
    let path = resolve_path(raw);
    fs::read_to_string(&path)
        .map_err(|e| CliError::new("patch.read", format!("Failed to read patch {path}: {e}")))
}
fn write_diff_html(title: &str, layout: &str, size: Option<f64>, patch: &str) -> Result<PathBuf> {
    let dir = env::temp_dir().join("cmux-diff-viewers");
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("diff-{}.html", uuid::Uuid::new_v4()));
    let html = format!(
        "<!doctype html><meta charset=utf-8><title>{}</title><style>body{{margin:0;background:#1e1e1e;color:#ddd;font:{}px ui-monospace,monospace}}header{{padding:12px 16px;font:14px -apple-system,sans-serif;background:#282828}}pre{{white-space:pre-wrap;padding:16px}}.add{{color:#9ece6a}}.del{{color:#f7768e}}</style><header>{} · {}</header><pre>{}</pre>",
        escape_html(title),
        size.unwrap_or(13.0),
        escape_html(title),
        layout,
        format_patch_html(patch)
    );
    fs::write(&path, html)?;
    Ok(path)
}
fn format_patch_html(patch: &str) -> String {
    patch
        .lines()
        .map(|line| {
            let e = escape_html(line);
            let c = if line.starts_with('+') && !line.starts_with("+++") {
                "add"
            } else if line.starts_with('-') && !line.starts_with("---") {
                "del"
            } else {
                ""
            };
            format!("<span class=\"{c}\">{e}</span>\n")
        })
        .collect()
}
fn escape_html(v: &str) -> String {
    v.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
fn parse_range(raw: &str, min: f64, max: f64, msg: &str) -> Result<f64> {
    let v = raw
        .trim()
        .parse::<f64>()
        .map_err(|_| CliError::usage(msg))?;
    if !(min..=max).contains(&v) {
        return Err(CliError::usage(msg));
    }
    Ok((v * 100.0).round() / 100.0)
}
fn resolve_path(raw: &str) -> String {
    let raw = if raw == "~" {
        env::var("HOME").unwrap_or_else(|_| raw.into())
    } else if let Some(rest) = raw.strip_prefix("~/") {
        format!("{}/{}", env::var("HOME").unwrap_or_default(), rest)
    } else {
        raw.into()
    };
    let p = PathBuf::from(raw);
    if p.is_absolute() {
        p.to_string_lossy().into_owned()
    } else {
        env::current_dir()
            .unwrap_or_default()
            .join(p)
            .to_string_lossy()
            .into_owned()
    }
}
fn file_url(path: &Path) -> String {
    format!(
        "file://{}",
        path.to_string_lossy()
            .replace('%', "%25")
            .replace(' ', "%20")
            .replace('#', "%23")
            .replace('?', "%3F")
    )
}
fn is_http_url(v: &str) -> bool {
    v.starts_with("http://") || v.starts_with("https://")
}
fn is_path_or_url(v: &str) -> bool {
    is_http_url(v)
        || v.starts_with('/')
        || v.starts_with('.')
        || v.starts_with('~')
        || v.contains('/')
}
fn atty_stdin() -> bool {
    unsafe { libc::isatty(libc::STDIN_FILENO) == 1 }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn html_escape() {
        assert_eq!(escape_html("<x>&\""), "&lt;x&gt;&amp;&quot;");
    }
    #[test]
    fn file_url_quotes() {
        assert_eq!(file_url(Path::new("/tmp/a b#c")), "file:///tmp/a%20b%23c");
    }
    #[test]
    fn range_bounds() {
        assert!(parse_range("8", 8., 96., "bad").is_ok());
        assert!(parse_range("7", 8., 96., "bad").is_err());
    }
}
