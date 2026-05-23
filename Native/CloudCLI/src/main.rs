use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::env;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_secs(15);
const VM_CREATE_RESPONSE_TIMEOUT: Duration = Duration::from_secs(16 * 60);
const VM_CREATE_IDEMPOTENCY_TTL: u64 = 10 * 60;

extern "C" {
    fn getuid() -> u32;
}

#[derive(Debug)]
struct CliError {
    message: String,
    exit_code: i32,
}

impl CliError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            exit_code: 1,
        }
    }

    fn exit(message: impl Into<String>, exit_code: i32) -> Self {
        Self {
            message: message.into(),
            exit_code,
        }
    }
}

type CliResult<T> = Result<T, CliError>;

#[derive(Debug, Clone)]
struct CloudContext {
    socket_path: String,
    socket_password: Option<String>,
    json_output: bool,
    id_format: Option<String>,
    window_override: Option<String>,
    parent_cli: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct VMCreateIdempotencyStore {
    #[serde(default)]
    records: std::collections::BTreeMap<String, VMCreateIdempotencyRecord>,
}

#[derive(Debug, Deserialize, Serialize)]
struct VMCreateIdempotencyRecord {
    key: String,
    #[serde(rename = "createdAt")]
    created_at: f64,
}

#[derive(Debug)]
struct ActiveVMCreateIdempotency {
    signature: String,
    key: String,
}

struct SocketClient {
    stream: UnixStream,
}

impl SocketClient {
    fn connect(path: String) -> CliResult<Self> {
        Self::connect_once(&path).map(|stream| Self { stream })
    }

    fn connect_once(path: &str) -> CliResult<UnixStream> {
        let metadata =
            fs::metadata(path).map_err(|_| CliError::new(format!("Socket not found at {path}")))?;
        if !metadata.file_type().is_socket() {
            return Err(CliError::new(format!(
                "Path exists at {path} but is not a Unix socket"
            )));
        }
        let current_uid = unsafe { getuid() };
        if metadata.uid() != current_uid {
            return Err(CliError::new(format!(
                "Socket at {path} is not owned by the current user, refusing to connect"
            )));
        }

        let stream = UnixStream::connect(path).map_err(|error| {
            CliError::new(format!("Failed to connect to socket at {path} ({error})"))
        })?;
        stream
            .set_read_timeout(Some(response_timeout()))
            .map_err(|error| {
                CliError::new(format!("Failed to configure socket timeout: {error}"))
            })?;
        stream
            .set_write_timeout(Some(response_timeout()))
            .map_err(|error| {
                CliError::new(format!("Failed to configure socket timeout: {error}"))
            })?;
        Ok(stream)
    }

    fn authenticate_if_needed(&mut self, password: Option<&str>) -> CliResult<()> {
        let Some(password) = password else {
            return Ok(());
        };
        let response = self.send_line(&format!("auth {password}"), response_timeout())?;
        if response.starts_with("ERROR:") && !response.contains("Unknown command 'auth'") {
            return Err(CliError::new(sanitized_auth_error(&response, password)));
        }
        Ok(())
    }

    fn send_v2(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> CliResult<Map<String, Value>> {
        let request = json!({
            "id": request_id(),
            "method": method,
            "params": params,
        });
        let raw = self.send_line(&request.to_string(), timeout)?;
        if raw.starts_with("ERROR:") {
            return Err(CliError::new(raw));
        }

        let response: Value = serde_json::from_str(&raw)
            .map_err(|_| CliError::new(format!("Invalid v2 response: {raw}")))?;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(response
                .get("result")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default());
        }
        if let Some(error) = response.get("error").and_then(Value::as_object) {
            let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Unknown v2 error");
            let action = error.get("action").and_then(Value::as_str);
            let reason = error.get("reason").and_then(Value::as_str);
            let details = safe_v2_details(error.get("details"));
            return Err(CliError::new(format_v2_error(
                code,
                message,
                action,
                reason,
                details.as_deref(),
            )));
        }
        Err(CliError::new("v2 request failed"))
    }

    fn send_line(&mut self, line: &str, timeout: Duration) -> CliResult<String> {
        self.stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| {
                CliError::new(format!("Failed to configure socket timeout: {error}"))
            })?;
        self.stream
            .set_write_timeout(Some(timeout))
            .map_err(|error| {
                CliError::new(format!("Failed to configure socket timeout: {error}"))
            })?;
        self.stream
            .write_all(line.as_bytes())
            .and_then(|_| self.stream.write_all(b"\n"))
            .map_err(|error| match error.kind() {
                ErrorKind::WouldBlock | ErrorKind::TimedOut => CliError::new("Command timed out"),
                _ => CliError::new(format!("Failed to write to socket ({error})")),
            })?;

        let mut data = Vec::new();
        let mut byte = [0_u8; 1];
        loop {
            match self.stream.read(&mut byte) {
                Ok(0) if data.is_empty() => {
                    return Err(CliError::new("Socket closed before reply"));
                }
                Ok(0) => break,
                Ok(_) if byte[0] == b'\n' => break,
                Ok(_) => data.push(byte[0]),
                Err(error) if matches!(error.kind(), ErrorKind::Interrupted) => {}
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    return Err(CliError::new("Command timed out"));
                }
                Err(error) => return Err(CliError::new(format!("Socket read error ({error})"))),
            }
        }

        String::from_utf8(data).map_err(|_| CliError::new("Invalid UTF-8 response"))
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Error: {}", error.message);
        process::exit(error.exit_code);
    }
}

fn run() -> CliResult<()> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    let json_from_args = take_flag_before_terminator(&mut args, "--json");
    if take_flag_before_terminator(&mut args, "--help")
        || take_flag_before_terminator(&mut args, "-h")
    {
        println!("{}", usage());
        return Ok(());
    }

    let ctx = CloudContext::from_env(json_from_args)?;
    let subcommand = args.first().map(|arg| arg.as_str()).unwrap_or("ls");
    let rest = if args.is_empty() {
        Vec::new()
    } else {
        args[1..].to_vec()
    };

    match subcommand {
        "ls" | "list" => run_list(&ctx),
        "new" | "create" => run_new(&ctx, &rest),
        "rm" | "destroy" | "delete" => run_destroy(&ctx, &rest),
        "exec" => run_exec(&ctx, &rest),
        "ssh-info" => run_ssh_info(&ctx, &rest),
        "shell" | "attach" | "ssh" => run_delegated_interactive(&ctx, subcommand, &rest),
        "ssh-attach" => {
            let mut vm_args = vec![subcommand.to_string()];
            vm_args.extend(rest);
            exec_parent_vm(&ctx, &vm_args)
        }
        "help" => {
            println!("{}", usage());
            Ok(())
        }
        _ => Err(CliError::exit(
            format!(
                "Usage: cmux cloud <ls|new|shell|rm|exec|ssh> [args...]\n\nCommon commands:\n  cmux cloud ls\n  cmux cloud new\n  cmux cloud ssh <id>\n  cmux cloud rm <id>"
            ),
            2,
        )),
    }
}

impl CloudContext {
    fn from_env(json_from_args: bool) -> CliResult<Self> {
        let socket_path = normalized_env("CMUX_CLOUD_SOCKET_PATH")
            .or_else(|| normalized_env("CMUX_SOCKET_PATH"))
            .or_else(|| normalized_env("CMUX_SOCKET"))
            .ok_or_else(|| {
                CliError::new("cmux cloud needs CMUX_SOCKET_PATH from the cmux launcher")
            })?;
        let socket_password = normalized_env("CMUX_CLOUD_SOCKET_PASSWORD")
            .or_else(|| normalized_env("CMUX_SOCKET_PASSWORD"));
        let json_output = json_from_args || env_flag("CMUX_CLOUD_JSON");
        let id_format = normalized_env("CMUX_CLOUD_ID_FORMAT");
        let window_override = normalized_env("CMUX_CLOUD_WINDOW");
        let parent_cli =
            normalized_env("CMUX_CLOUD_PARENT_CLI").unwrap_or_else(|| "cmux".to_string());
        Ok(Self {
            socket_path,
            socket_password,
            json_output,
            id_format,
            window_override,
            parent_cli,
        })
    }

    fn connect(&self) -> CliResult<SocketClient> {
        let mut client = SocketClient::connect(self.socket_path.clone())?;
        client.authenticate_if_needed(self.socket_password.as_deref())?;
        if let Some(window_raw) = &self.window_override {
            let normalized = normalize_window_handle(&mut client, window_raw)?
                .unwrap_or_else(|| window_raw.to_string());
            client.send_v2(
                "window.focus",
                json!({ "window_id": normalized }),
                response_timeout(),
            )?;
        }
        Ok(client)
    }
}

fn run_list(ctx: &CloudContext) -> CliResult<()> {
    let mut client = ctx.connect()?;
    let response = client.send_v2("vm.list", json!({}), response_timeout())?;
    if ctx.json_output {
        println!("{}", Value::Object(response));
        return Ok(());
    }

    let vms = response
        .get("vms")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if vms.is_empty() {
        println!("No cloud VMs. Try: cmux cloud new");
        return Ok(());
    }

    for vm in vms {
        let id = value_str(vm.get("id")).unwrap_or("?");
        let provider = value_str(vm.get("provider")).unwrap_or("?");
        let image = value_str(vm.get("image")).unwrap_or("?");
        println!("{id}  [{provider}] {image}");
    }
    Ok(())
}

fn run_new(ctx: &CloudContext, args: &[String]) -> CliResult<()> {
    let (image_opt, rem0) = parse_option(args, "--image");
    let (provider_opt, rem1) = parse_option(&rem0, "--provider");
    let (window_opt, rem2) = parse_option(&rem1, "--window");
    let detach = rem2.iter().any(|arg| arg == "--detach" || arg == "-d");
    let remaining = rem2
        .into_iter()
        .filter(|arg| arg != "--detach" && arg != "-d")
        .collect::<Vec<_>>();

    if let Some(unknown) = remaining
        .iter()
        .find(|arg| is_unknown_flag_token(arg, &["-d"]))
    {
        return Err(CliError::exit(
            format!(
                "cloud new: unknown flag '{unknown}'.\n\nKnown flags:\n  --image <image-id>\n  --provider <provider>\n  --detach, -d\n\nTry:\n  cmux cloud new"
            ),
            2,
        ));
    }
    if let Some(extra) = remaining.iter().find(|arg| !is_flag_token(arg)) {
        return Err(CliError::exit(
            format!(
                "cloud new: unexpected argument '{extra}'.\n\n`cmux cloud new` does not take a VM name or positional arguments.\n\nTry:\n  cmux cloud new\n  cmux cloud new --detach"
            ),
            2,
        ));
    }

    let provider = normalized_vm_provider(provider_opt.as_deref())?;
    let mut client = ctx.connect()?;
    let effective_window = window_opt.as_ref().or(ctx.window_override.as_ref());
    let target_window = match effective_window {
        Some(raw) => validate_window_handle(&mut client, raw)?,
        None => None,
    };

    let idempotency = active_vm_create_idempotency(image_opt.as_deref(), provider.as_deref())?;
    let mut params = Map::new();
    if let Some(image) = &image_opt {
        params.insert("image".to_string(), Value::String(image.clone()));
    }
    if let Some(provider) = &provider {
        params.insert("provider".to_string(), Value::String(provider.clone()));
    }
    params.insert(
        "idempotency_key".to_string(),
        Value::String(idempotency.key.clone()),
    );

    let response = client.send_v2(
        "vm.create",
        Value::Object(params),
        VM_CREATE_RESPONSE_TIMEOUT,
    )?;
    if ctx.json_output {
        clear_vm_create_idempotency(&idempotency)?;
        println!("{}", Value::Object(response));
        return Ok(());
    }

    let id = response
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("?")
        .to_string();
    let provider_text = value_str(response.get("provider")).unwrap_or("?");
    let image_text = value_str(response.get("image")).unwrap_or("?");
    if detach {
        clear_vm_create_idempotency(&idempotency)?;
        println!("OK {id}");
        println!("  provider: {provider_text}");
        println!("  image:    {image_text}");
        return Ok(());
    }

    println!("Created {id}  [{provider_text}]  {image_text}");
    drop(client);

    let mut vm_args = vec!["shell".to_string(), id];
    if let Some(window) = target_window {
        vm_args.push("--window".to_string());
        vm_args.push(window);
    }
    run_parent_vm_session(ctx, &vm_args)?;
    clear_vm_create_idempotency(&idempotency)
}

fn run_destroy(ctx: &CloudContext, args: &[String]) -> CliResult<()> {
    let Some(vm_id) = args.first() else {
        return Err(CliError::exit(
            "Usage: cmux cloud rm <id>\n\nFind an id:\n  cmux cloud ls",
            2,
        ));
    };
    let mut client = ctx.connect()?;
    client.send_v2(
        "vm.destroy",
        json!({ "id": vm_id }),
        Duration::from_secs(60),
    )?;
    if ctx.json_output {
        println!("{}", json!({ "ok": true, "id": vm_id }));
    } else {
        println!("OK {vm_id}");
    }
    Ok(())
}

fn run_exec(ctx: &CloudContext, args: &[String]) -> CliResult<()> {
    let Some(vm_id) = args.first() else {
        return Err(CliError::exit(
            "Usage: cmux cloud exec <id> -- <command...>\n\nExamples:\n  cmux cloud ls\n  cmux cloud exec <id> -- pwd",
            2,
        ));
    };
    let mut command_args = args[1..].to_vec();
    if command_args.first().map(String::as_str) == Some("--") {
        command_args.remove(0);
    }
    if command_args.is_empty() {
        return Err(CliError::exit(
            format!(
                "Usage: cmux cloud exec <id> -- <command...>\n\nExample:\n  cmux cloud exec {vm_id} -- uname -a"
            ),
            2,
        ));
    }

    let command = command_args
        .iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ");
    let mut client = ctx.connect()?;
    let response = client.send_v2(
        "vm.exec",
        json!({ "id": vm_id, "command": command }),
        Duration::from_secs(35),
    )?;
    let exit_code = response
        .get("exit_code")
        .and_then(Value::as_i64)
        .unwrap_or(-1);
    if ctx.json_output {
        println!("{}", Value::Object(response));
        if exit_code != 0 {
            return Err(CliError::exit(
                format!("exit {exit_code}"),
                process_exit_code(exit_code),
            ));
        }
        return Ok(());
    }

    if let Some(stdout) = response.get("stdout").and_then(Value::as_str) {
        if !stdout.is_empty() {
            print!("{stdout}");
            if !stdout.ends_with('\n') {
                println!();
            }
        }
    }
    if let Some(stderr) = response.get("stderr").and_then(Value::as_str) {
        if !stderr.is_empty() {
            eprint!("{stderr}");
            if !stderr.ends_with('\n') {
                eprintln!();
            }
        }
    }
    if exit_code != 0 {
        return Err(CliError::exit(
            format!("exit {exit_code}"),
            process_exit_code(exit_code),
        ));
    }
    Ok(())
}

fn run_ssh_info(ctx: &CloudContext, args: &[String]) -> CliResult<()> {
    let Some(vm_id) = args.first() else {
        return Err(CliError::exit(
            "Usage: cmux cloud ssh-info <id>\n\nFind an id:\n  cmux cloud ls",
            2,
        ));
    };
    let mut client = ctx.connect()?;
    let response = client.send_v2(
        "vm.ssh_info",
        json!({ "id": vm_id }),
        Duration::from_secs(60),
    )?;
    if ctx.json_output {
        println!("{}", Value::Object(response));
        return Ok(());
    }

    let host = value_str(response.get("host")).unwrap_or("?");
    let port = response.get("port").and_then(Value::as_i64).unwrap_or(22);
    let username = value_str(response.get("username")).unwrap_or("?");
    let credential = response.get("credential").and_then(Value::as_object);
    let cred_kind = credential
        .and_then(|cred| cred.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("?");
    let cred_value = credential
        .and_then(|cred| cred.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("?");
    if cred_kind == "password" {
        println!("ssh {username}@{host} -p {port}");
        println!();
        println!("  host:      {host}");
        println!("  port:      {port}");
        println!("  username:  {username}");
        println!("  password:  {cred_value}");
        return Ok(());
    }

    println!("This Cloud VM does not support `cmux cloud ssh-info` in this cmux build.");
    println!();
    println!("What to do:");
    println!("  Update cmux and retry.");
    println!("  If this keeps happening, contact support with the VM id.");
    Ok(())
}

fn run_delegated_interactive(
    ctx: &CloudContext,
    subcommand: &str,
    args: &[String],
) -> CliResult<()> {
    let (window_opt, vm_args) = parse_option(args, "--window");
    let Some(vm_id) = vm_args.first() else {
        return Err(CliError::exit(
            format!("Usage: cmux cloud {subcommand} <id>\n\nFind an id:\n  cmux cloud ls"),
            2,
        ));
    };

    let mut delegated = vec![subcommand.to_string(), vm_id.clone()];
    if let Some(window) = window_opt.or_else(|| ctx.window_override.clone()) {
        delegated.push("--window".to_string());
        delegated.push(window);
    }
    exec_parent_vm(ctx, &delegated)
}

fn exec_parent_vm(ctx: &CloudContext, vm_args: &[String]) -> CliResult<()> {
    let mut command = Command::new(&ctx.parent_cli);
    command.args(parent_vm_args(ctx, vm_args));
    for (key, value) in parent_vm_env(ctx) {
        command.env(key, value);
    }
    let error = command.exec();
    Err(CliError::new(format!(
        "Could not open the Cloud VM session: {error}"
    )))
}

fn run_parent_vm_session(ctx: &CloudContext, vm_args: &[String]) -> CliResult<()> {
    let mut command = Command::new(&ctx.parent_cli);
    command.args(parent_vm_args(ctx, vm_args));
    for (key, value) in parent_vm_env(ctx) {
        command.env(key, value);
    }
    let status = command
        .status()
        .map_err(|error| CliError::new(format!("Could not open the Cloud VM session: {error}")))?;
    if status.success() {
        return Ok(());
    }
    if let Some(code) = status.code() {
        return Err(CliError::exit(format!("exit {code}"), code));
    }
    if let Some(signal) = status.signal() {
        let code = 128 + signal;
        return Err(CliError::exit(format!("signal {signal}"), code));
    }
    Err(CliError::new("cmux vm helper exited unsuccessfully"))
}

fn parent_vm_args(ctx: &CloudContext, vm_args: &[String]) -> Vec<String> {
    let mut args = vec!["--socket".to_string(), ctx.socket_path.clone()];
    if ctx.json_output {
        args.push("--json".to_string());
    }
    if let Some(id_format) = &ctx.id_format {
        args.push("--id-format".to_string());
        args.push(id_format.clone());
    }
    args.push("vm".to_string());
    args.extend(vm_args.iter().cloned());
    args
}

fn parent_vm_env(ctx: &CloudContext) -> Vec<(&'static str, String)> {
    let Some(password) = &ctx.socket_password else {
        return Vec::new();
    };
    vec![
        ("CMUX_SOCKET_PASSWORD", password.clone()),
        ("CMUX_CLOUD_SOCKET_PASSWORD", password.clone()),
    ]
}

fn validate_window_handle(client: &mut SocketClient, raw: &str) -> CliResult<Option<String>> {
    let Some(normalized) = normalize_window_handle(client, raw)? else {
        return Ok(None);
    };
    let listed = client.send_v2("window.list", json!({}), response_timeout())?;
    let windows = listed
        .get("windows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let found = windows
        .iter()
        .any(|item| window_handle_matches(&normalized, item));
    if !found {
        return Err(CliError::new(format!("Window not found: {raw}")));
    }
    Ok(Some(normalized))
}

fn normalize_window_handle(client: &mut SocketClient, raw: &str) -> CliResult<Option<String>> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if is_uuid(trimmed) {
        return Ok(Some(trimmed.to_string()));
    }
    if is_handle_ref(trimmed) {
        if let Some(matched) = matching_window_handle(client, trimmed)? {
            return Ok(Some(matched));
        }
        return Err(CliError::new(format!("Window not found: {trimmed}")));
    }

    let wanted_index = trimmed.parse::<i64>().map_err(|_| {
        CliError::new(format!(
            "Invalid window handle: {trimmed} (expected UUID, ref like window:1, or index)"
        ))
    })?;
    let listed = client.send_v2("window.list", json!({}), response_timeout())?;
    let windows = listed
        .get("windows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for item in windows {
        if item.get("index").and_then(Value::as_i64) == Some(wanted_index) {
            if let Some(id) = item.get("id").and_then(Value::as_str) {
                return Ok(Some(id.to_string()));
            }
            if let Some(reference) = item.get("ref").and_then(Value::as_str) {
                return Ok(Some(reference.to_string()));
            }
        }
    }
    Err(CliError::new("Window index not found"))
}

fn matching_window_handle(client: &mut SocketClient, handle: &str) -> CliResult<Option<String>> {
    let listed = client.send_v2("window.list", json!({}), response_timeout())?;
    let windows = listed
        .get("windows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for item in windows {
        if window_handle_matches(handle, &item) {
            if let Some(id) = item.get("id").and_then(Value::as_str) {
                return Ok(Some(id.to_string()));
            }
            if let Some(reference) = item.get("ref").and_then(Value::as_str) {
                return Ok(Some(reference.to_string()));
            }
            return Ok(Some(handle.to_string()));
        }
    }
    Ok(None)
}

fn window_handle_matches(handle: &str, item: &Value) -> bool {
    let Some(target) = normalized_handle_value(Some(handle)) else {
        return false;
    };
    for key in ["id", "ref"] {
        let candidate = item.get(key).and_then(Value::as_str);
        if let Some(candidate) = normalized_handle_value(candidate) {
            if handles_match(&target, &candidate) {
                return true;
            }
        }
    }
    false
}

fn request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("cmux-cloud-{}-{nanos}", process::id())
}

fn response_timeout() -> Duration {
    match normalized_env("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC")
        .and_then(|raw| raw.parse::<f64>().ok())
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
    {
        Some(seconds) => Duration::from_secs_f64(seconds),
        None => DEFAULT_RESPONSE_TIMEOUT,
    }
}

fn sanitized_auth_error(response: &str, password: &str) -> String {
    let redacted = response.replace(password, "<redacted>");
    format!("Socket authentication failed: {redacted}")
}

fn normalized_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_flag(name: &str) -> bool {
    matches!(
        normalized_env(name).as_deref(),
        Some("1" | "true" | "TRUE" | "yes" | "YES")
    )
}

fn take_flag_before_terminator(args: &mut Vec<String>, flag: &str) -> bool {
    let mut found = false;
    let mut filtered = Vec::with_capacity(args.len());
    let mut past_terminator = false;
    for arg in args.drain(..) {
        if past_terminator {
            filtered.push(arg);
            continue;
        }
        if arg == "--" {
            past_terminator = true;
            filtered.push(arg);
            continue;
        }
        if arg == flag {
            found = true;
        } else {
            filtered.push(arg);
        }
    }
    *args = filtered;
    found
}

fn parse_option(args: &[String], name: &str) -> (Option<String>, Vec<String>) {
    let mut remaining = Vec::new();
    let mut value = None;
    let mut index = 0;
    let mut past_terminator = false;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            past_terminator = true;
            remaining.push(arg.clone());
            index += 1;
            continue;
        }
        if !past_terminator {
            let equals_prefix = format!("{name}=");
            if arg.starts_with(&equals_prefix) {
                value = Some(arg[equals_prefix.len()..].to_string());
                index += 1;
                continue;
            }
            if arg == name && index + 1 < args.len() {
                value = Some(args[index + 1].clone());
                index += 2;
                continue;
            }
        }
        remaining.push(arg.clone());
        index += 1;
    }
    (value, remaining)
}

fn normalized_vm_provider(provider: Option<&str>) -> CliResult<Option<String>> {
    let Some(provider) = provider.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let normalized = provider.to_ascii_lowercase();
    if normalized == "e2b" || normalized == "freestyle" {
        return Ok(Some(normalized));
    }
    Err(CliError::exit(
        "cloud new: unsupported Cloud VM service override.\n\nTry:\n  cmux cloud new",
        2,
    ))
}

fn is_flag_token(value: &str) -> bool {
    value.starts_with('-') && value != "-"
}

fn is_unknown_flag_token(value: &str, allowed_short_flags: &[&str]) -> bool {
    is_flag_token(value) && !allowed_short_flags.contains(&value)
}

fn process_exit_code(exit_code: i64) -> i32 {
    if (0..=255).contains(&exit_code) {
        exit_code as i32
    } else {
        1
    }
}

fn idempotency_signature(image: Option<&str>, provider: Option<&str>) -> String {
    format!(
        "image={}\u{1f}provider={}",
        image.unwrap_or("").trim(),
        provider.unwrap_or("").trim().to_ascii_lowercase()
    )
}

fn vm_create_idempotency_store_url() -> CliResult<PathBuf> {
    let home = env::var("HOME")
        .map_err(|_| CliError::new("HOME is not set, cannot store VM idempotency state"))?;
    Ok(Path::new(&home)
        .join(".cmuxterm")
        .join("vm-create-idempotency.json"))
}

fn load_vm_create_idempotency_store(path: &Path) -> VMCreateIdempotencyStore {
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(VMCreateIdempotencyStore {
            records: std::collections::BTreeMap::new(),
        })
}

fn save_vm_create_idempotency_store(
    store: &VMCreateIdempotencyStore,
    path: &Path,
) -> CliResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliError::new(format!(
                "Failed to create VM idempotency state directory: {error}"
            ))
        })?;
    }
    let data = serde_json::to_vec_pretty(store).map_err(|error| {
        CliError::new(format!("Failed to encode VM idempotency state: {error}"))
    })?;
    fs::write(path, data)
        .map_err(|error| CliError::new(format!("Failed to write VM idempotency state: {error}")))
}

fn active_vm_create_idempotency(
    image: Option<&str>,
    provider: Option<&str>,
) -> CliResult<ActiveVMCreateIdempotency> {
    let path = vm_create_idempotency_store_url()?;
    let signature = idempotency_signature(image, provider);
    let now = unix_timestamp_secs();
    let mut store = load_vm_create_idempotency_store(&path);
    store.records.retain(|_, record| {
        !record.key.is_empty()
            && now.saturating_sub(record.created_at as u64) < VM_CREATE_IDEMPOTENCY_TTL
    });
    if let Some(existing) = store.records.get(&signature) {
        save_vm_create_idempotency_store(&store, &path)?;
        return Ok(ActiveVMCreateIdempotency {
            signature,
            key: existing.key.clone(),
        });
    }

    let key = random_uuid_like();
    store.records.insert(
        signature.clone(),
        VMCreateIdempotencyRecord {
            key: key.clone(),
            created_at: now as f64,
        },
    );
    save_vm_create_idempotency_store(&store, &path)?;
    Ok(ActiveVMCreateIdempotency { signature, key })
}

fn clear_vm_create_idempotency(active: &ActiveVMCreateIdempotency) -> CliResult<()> {
    let path = vm_create_idempotency_store_url()?;
    let mut store = load_vm_create_idempotency_store(&path);
    if store
        .records
        .get(&active.signature)
        .map(|record| record.key.as_str())
        == Some(active.key.as_str())
    {
        store.records.remove(&active.signature);
        save_vm_create_idempotency_store(&store, &path)?;
    }
    Ok(())
}

fn unix_timestamp_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn random_uuid_like() -> String {
    let mut bytes = [0_u8; 16];
    if fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .is_err()
    {
        let fallback = request_id();
        for (index, byte) in fallback.as_bytes().iter().take(16).enumerate() {
            bytes[index] = *byte;
        }
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

fn shell_quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || "_@%+=:,./-".contains(ch))
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn value_str(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

fn safe_v2_details(value: Option<&Value>) -> Option<String> {
    let Some(value) = value else {
        return None;
    };
    if let Some(text) = value
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return Some(text.to_string());
    }
    let object = value.as_object()?;
    let allowed = [
        "amount",
        "code",
        "duration",
        "durationMs",
        "field",
        "idempotencyKeySet",
        "imageRequested",
        "limit",
        "operation",
        "retryable",
        "status",
        "type",
        "vmId",
    ];
    let mut lines = Vec::new();
    for key in allowed {
        if let Some(value) = object.get(key).filter(|value| !value.is_null()) {
            lines.push(format!("{key}: {}", safe_v2_detail_value(value)));
        }
    }
    if lines.is_empty() {
        None
    } else {
        Some(lines.join("\n"))
    }
}

fn safe_v2_detail_value(value: &Value) -> String {
    match value {
        Value::String(value) => value.replace('\n', "\\n").replace('\r', "\\r"),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        _ => "<redacted>".to_string(),
    }
}

fn format_v2_error(
    code: &str,
    message: &str,
    action: Option<&str>,
    reason: Option<&str>,
    details: Option<&str>,
) -> String {
    let header = if code == "vm_error" {
        message.to_string()
    } else if message.contains('\n') {
        format!("{code}:\n{message}")
    } else {
        format!("{code}: {message}")
    };
    let mut sections = vec![header];
    if let Some(reason) = trimmed_non_empty(reason) {
        sections.push(format!("Reason:\n{}", indent_v2_error_lines(reason)));
    }
    if let Some(action) = trimmed_non_empty(action) {
        sections.push(format!("What to do:\n{}", indent_v2_error_lines(action)));
    }
    if let Some(details) = trimmed_non_empty(details) {
        sections.push(format!("Details:\n{}", indent_v2_error_lines(details)));
    }
    sections.join("\n\n")
}

fn trimmed_non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn indent_v2_error_lines(value: &str) -> String {
    value
        .lines()
        .map(|line| format!("  {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && [8, 13, 18, 23].iter().all(|index| bytes[*index] == b'-')
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| [8, 13, 18, 23].contains(&index) || byte.is_ascii_hexdigit())
}

fn is_handle_ref(value: &str) -> bool {
    let Some((kind, index)) = value.split_once(':') else {
        return false;
    };
    matches!(
        kind.to_ascii_lowercase().as_str(),
        "window" | "workspace" | "pane" | "surface"
    ) && index.parse::<i64>().is_ok()
}

fn normalized_handle_value(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn handles_match(lhs: &str, rhs: &str) -> bool {
    lhs.eq_ignore_ascii_case(rhs)
}

fn usage() -> &'static str {
    "Usage: cmux cloud <new|ls|rm|exec|shell|attach|ssh|ssh-info> [args...]\n\nManage cloud VMs. Requires `cmux auth login`.\n\nSubcommands:\n  ls                        List your cloud VMs.\n  new [--image <template>] [--provider <provider>] [--window <id|ref|index>] [--detach|-d]\n                            Create a new VM. By default drops you into a shell on\n                            the VM. Pass --detach/-d to just print the id and exit.\n  shell <id> [--window <id|ref|index>]\n                            Drop into an interactive shell on an existing VM.\n                            Alias: `attach <id>`.\n  ssh <id> [--window <id|ref|index>]\n                            Drop into a cmux-managed SSH workspace for an existing VM.\n  ssh-info <id>             Print SSH connection details when the Cloud VM exposes SSH.\n  rm <id>                   Destroy a VM.\n  exec <id> -- <command...> Run a shell command inside the VM and print stdout.\n\nEnv:\n  CMUX_VM_API_BASE_URL       Override the backend origin (default: the cmux website).\n                             `bun run dev` derives this from CMUX_PORT/PORT for local testing.\n\nExample:\n  cmux cloud new\n  cmux cloud ls\n  cmux cloud exec <id> -- echo hello\n  cmux cloud rm <id>"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_option_supports_equals_and_terminator() {
        let args = vec![
            "--image=abc".to_string(),
            "--".to_string(),
            "--image".to_string(),
            "ignored".to_string(),
        ];
        let (value, remaining) = parse_option(&args, "--image");
        assert_eq!(value.as_deref(), Some("abc"));
        assert_eq!(remaining, vec!["--", "--image", "ignored"]);
    }

    #[test]
    fn shell_quote_preserves_argv_boundaries() {
        assert_eq!(shell_quote("abc-123"), "abc-123");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("can't"), "'can'\"'\"'t'");
    }

    #[test]
    fn global_flags_do_not_consume_remote_exec_args() {
        let mut args = vec![
            "exec".to_string(),
            "vm_123".to_string(),
            "--".to_string(),
            "--help".to_string(),
            "--json".to_string(),
        ];
        assert!(!take_flag_before_terminator(&mut args, "--help"));
        assert!(!take_flag_before_terminator(&mut args, "--json"));
        assert_eq!(args, vec!["exec", "vm_123", "--", "--help", "--json"]);
    }

    #[test]
    fn provider_validation_accepts_supported_values() {
        assert_eq!(
            normalized_vm_provider(Some(" Freestyle "))
                .unwrap()
                .as_deref(),
            Some("freestyle")
        );
        assert!(normalized_vm_provider(Some("bad")).is_err());
    }

    #[test]
    fn usage_mentions_cloud_entrypoint() {
        assert!(usage().contains("Usage: cmux cloud"));
        assert!(usage().contains("cmux cloud new"));
    }

    #[test]
    fn parent_vm_delegation_keeps_password_out_of_argv() {
        let ctx = CloudContext {
            socket_path: "/tmp/cmux.sock".to_string(),
            socket_password: Some("secret-password".to_string()),
            json_output: true,
            id_format: Some("short".to_string()),
            window_override: None,
            parent_cli: "cmux".to_string(),
        };
        let args = parent_vm_args(&ctx, &["ssh".to_string(), "vm_123".to_string()]);
        assert_eq!(
            args,
            vec![
                "--socket",
                "/tmp/cmux.sock",
                "--json",
                "--id-format",
                "short",
                "vm",
                "ssh",
                "vm_123"
            ]
        );
        assert!(!args.iter().any(|arg| arg == "--password"));
        assert!(!args.iter().any(|arg| arg == "secret-password"));

        let env = parent_vm_env(&ctx);
        assert!(env.contains(&("CMUX_SOCKET_PASSWORD", "secret-password".to_string())));
        assert!(env.contains(&("CMUX_CLOUD_SOCKET_PASSWORD", "secret-password".to_string())));
    }

    #[test]
    fn auth_errors_redact_password() {
        let message = sanitized_auth_error("ERROR: auth secret-password failed", "secret-password");
        assert!(message.contains("<redacted>"));
        assert!(!message.contains("secret-password"));
    }

    #[test]
    fn remote_exec_exit_codes_are_preserved_when_valid() {
        assert_eq!(process_exit_code(0), 0);
        assert_eq!(process_exit_code(2), 2);
        assert_eq!(process_exit_code(255), 255);
        assert_eq!(process_exit_code(-1), 1);
        assert_eq!(process_exit_code(300), 1);
    }
}
