use serde_json::{Value, json};
use std::{
    fmt, io,
    time::{Duration, Instant},
};

pub mod args;
pub mod commands;
pub mod resolver;
pub mod transport;

pub type Result<T> = std::result::Result<T, CliError>;

#[derive(Debug, Clone)]
pub struct CliError {
    pub code: String,
    pub message: String,
    pub exit_code: i32,
    pub retryable: bool,
    pub next: Vec<String>,
}
impl CliError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            exit_code: 1,
            retryable: false,
            next: vec![],
        }
    }
    pub fn usage(message: impl Into<String>) -> Self {
        Self {
            code: "usage.invalid".into(),
            message: message.into(),
            exit_code: 2,
            retryable: false,
            next: vec![],
        }
    }
    pub fn next(mut self, command: impl Into<String>) -> Self {
        self.next.push(command.into());
        self
    }
    pub fn exit(mut self, code: i32) -> Self {
        self.exit_code = code;
        self
    }
    pub fn envelope(&self) -> Value {
        json!({"ok":false,"error":{"code":self.code,"message":self.message,"retryable":self.retryable,"next":self.next}})
    }
}
impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for CliError {}
impl From<io::Error> for CliError {
    fn from(e: io::Error) -> Self {
        Self::new("io.error", e.to_string())
    }
}
impl From<serde_json::Error> for CliError {
    fn from(e: serde_json::Error) -> Self {
        Self::new("json.error", e.to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Context {
    pub json: bool,
    pub envelope: bool,
    pub non_interactive: bool,
    pub dry_run: bool,
    pub explain: bool,
    pub socket: Option<String>,
    pub password: Option<String>,
    pub window: Option<String>,
    pub id_format: String,
    pub timeout: Duration,
    pub started: Instant,
}
impl Default for Context {
    fn default() -> Self {
        Self {
            json: false,
            envelope: false,
            non_interactive: false,
            dry_run: false,
            explain: false,
            socket: None,
            password: None,
            window: None,
            id_format: "refs".into(),
            timeout: Duration::from_secs(15),
            started: Instant::now(),
        }
    }
}
impl Context {
    pub fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        transport::rpc(self, method, params)
    }
    pub fn raw(&self, command: &str) -> Result<String> {
        transport::raw(self, command)
    }
    pub fn resolve_id(&self, kind: &str, value: Option<&str>) -> Result<Option<String>> {
        resolver::resolve(self, kind, value)
    }
    pub fn emit(&self, value: &Value) -> Result<()> {
        let output = if self.envelope {
            json!({"ok":true,"data":value,"meta":{"schema_version":1}})
        } else {
            value.clone()
        };
        println!(
            "{}",
            if self.json || self.envelope {
                serde_json::to_string_pretty(&output)?
            } else {
                human_value(&output)
            }
        );
        Ok(())
    }
    pub fn print(&self, value: impl AsRef<str>) -> Result<()> {
        println!("{}", value.as_ref());
        Ok(())
    }
    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }
}
fn human_value(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        _ => serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".into()),
    }
}

pub fn run<I, S>(argv: I) -> i32
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args: Vec<String> = argv.into_iter().map(Into::into).collect();
    let _ = args.first().cloned().map(|_| args.remove(0));
    let machine = args.iter().enumerate().any(|(i, a)| {
        a == "--json"
            || a == "--output=json"
            || (a == "--output" && args.get(i + 1).is_some_and(|v| v == "json" || v == "jsonl"))
    });
    let fallback_args = args.clone();
    match dispatch(&mut args) {
        Ok(code) => code,
        Err(e) => {
            if e.code == "command.unknown" {
                if let Some(code) = try_swift_fallback(&fallback_args) {
                    return code;
                }
            }
            if machine {
                println!("{}", e.envelope());
            } else {
                let _ = eprintln!("cmux: {}", e.message);
                if !e.next.is_empty() {
                    let _ = eprintln!("Next: {}", e.next.join(" or "));
                }
            }
            e.exit_code
        }
    }
}

/// Keep the app's legacy Swift CLI beside the Rust binary during migration.
/// Rust owns discovery, global parsing, and every migrated command; an
/// unclaimed legacy verb delegates to the exact app-revision sibling so a
/// partial migration cannot break existing automation.
fn try_swift_fallback(args: &[String]) -> Option<i32> {
    let explicit = std::env::var_os("CMUX_CLI_SWIFT_FALLBACK").map(std::path::PathBuf::from);
    let sibling = std::env::current_exe().ok().map(|path| {
        let mut value = path;
        let name = value
            .file_name()
            .and_then(|v| v.to_str())
            .unwrap_or("cmux")
            .to_string();
        value.set_file_name(format!("{name}-swift"));
        value
    });
    let executable = explicit.or(sibling)?;
    if !executable.is_file() || !executable.exists() {
        return None;
    }
    let status = std::process::Command::new(executable)
        .args(args)
        .status()
        .ok()?;
    Some(status.code().unwrap_or(1))
}
pub fn dispatch(args: &mut Vec<String>) -> Result<i32> {
    let mut ctx = Context::default();
    parse_global(args, &mut ctx)?;
    if args.is_empty() {
        return Err(CliError::usage("Missing command. Run `cmux --help`."));
    }
    let command = args.remove(0).to_lowercase();
    if matches!(command.as_str(), "help" | "--help" | "-h") {
        print_help(args.first().map(String::as_str));
        return Ok(0);
    }
    if matches!(command.as_str(), "version" | "--version" | "-v") {
        println!("cmux rust-cli 0.1.0");
        return Ok(0);
    }
    if command == "capabilities" {
        let value = json!({"product":"cmux","cli_version":"0.1.0","protocol_version":2,"output_modes":["text","json","jsonl"],"features":["socket","command_manifest","structured_errors"],"commands":["help","version","capabilities"]});
        if ctx.json {
            ctx.emit(&value)?;
        } else {
            println!("cmux capabilities: socket, command_manifest, structured_errors");
        }
        return Ok(0);
    }
    let modules: &[fn(&Context, &str, &[String]) -> Result<Option<i32>>] = commands::ALL;
    for module in modules {
        if let Some(code) = module(&ctx, &command, args)? {
            return Ok(code);
        }
    }
    Err(CliError::new(
        "command.unknown",
        format!("Unknown command `{command}`. Run `cmux --help`."),
    ))
}
fn parse_global(args: &mut Vec<String>, ctx: &mut Context) -> Result<()> {
    let mut out = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => ctx.json = true,
            "--output" => {
                i += 1;
                match args.get(i).map(String::as_str) {
                    Some("json") => {
                        ctx.json = true;
                        ctx.envelope = true
                    }
                    Some("jsonl") => ctx.json = true,
                    Some("text") => {}
                    Some(v) => {
                        return Err(CliError::usage(format!(
                            "--output expects text|json|jsonl, got {v}"
                        )));
                    }
                    None => return Err(CliError::usage("--output requires a value")),
                }
            }
            "--non-interactive" => ctx.non_interactive = true,
            "--dry-run" => ctx.dry_run = true,
            "--explain" => ctx.explain = true,
            "--socket" => {
                i += 1;
                ctx.socket = Some(
                    args.get(i)
                        .ok_or_else(|| CliError::usage("--socket requires a path"))?
                        .clone(),
                )
            }
            "--password" => {
                i += 1;
                ctx.password = Some(
                    args.get(i)
                        .ok_or_else(|| CliError::usage("--password requires a value"))?
                        .clone(),
                )
            }
            "--window" => {
                i += 1;
                ctx.window = Some(
                    args.get(i)
                        .ok_or_else(|| CliError::usage("--window requires an id"))?
                        .clone(),
                )
            }
            "--id-format" => {
                i += 1;
                ctx.id_format = args
                    .get(i)
                    .ok_or_else(|| CliError::usage("--id-format requires refs|uuids|both"))?
                    .clone();
                if !matches!(ctx.id_format.as_str(), "refs" | "uuids" | "both") {
                    return Err(CliError::usage("--id-format requires refs|uuids|both"));
                }
            }
            _ => out.push(args[i].clone()),
        }
        i += 1;
    }
    *args = out;
    Ok(())
}
fn print_help(scope: Option<&str>) {
    if let Some(s) = scope {
        println!("Usage: cmux {s} [options]");
    } else {
        println!(
            "cmux Rust CLI\nUsage: cmux <command> [options]\n\nGlobal: --json --output text|json|jsonl --non-interactive --dry-run --explain --socket PATH --window ID\nRun `cmux <command> --help` for command help."
        );
    }
}
