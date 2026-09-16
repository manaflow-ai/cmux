//! The Rust CLI's small, dependency-light control socket transport.
//!
//! The app still owns the socket server.  This module intentionally keeps the
//! wire protocol here instead of shelling out to the old Swift executable so
//! every Rust command observes the same timeout, authentication, and relay
//! behavior.

use crate::{Context, CliError, Result};
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::io::{BufRead, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::io::FromRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);
const MULTILINE_IDLE: Duration = Duration::from_millis(120);
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

pub fn rpc(ctx: &Context, method: &str, params: Value) -> Result<Value> {
    let mut params = params;
    if method.starts_with("vm.") {
        if let Value::Object(ref mut object) = params {
            for (key, variable) in [
                ("cloud_operation_id", "CMUX_CLOUD_OPERATION_ID"),
                ("cloud_trace_id", "CMUX_CLOUD_TRACE_ID"),
                ("cloud_parent_span_id", "CMUX_CLOUD_PARENT_SPAN_ID"),
            ] {
                if let Ok(value) = env::var(variable) {
                    if !value.is_empty() {
                        object.entry(key).or_insert(Value::String(value));
                    }
                }
            }
        }
    }
    let mut request = json!({
        "id": uuid::Uuid::new_v4().to_string().to_uppercase(),
        "method": method,
        "params": params,
    });
    if let Ok(rule_id) = env::var("CMUX_AUTOMATION_RULE_ID") {
        if !rule_id.is_empty() {
            request["automation_origin"] = automation_origin(&rule_id);
        }
    }
    let raw_request = serde_json::to_string(&request)
        .map_err(|e| CliError::new("encode", format!("Failed to encode v2 request: {e}")))?;
    let raw_response = raw(ctx, &raw_request)?;
    if raw_response.starts_with("ERROR:") {
        return Err(CliError::new("socket_error", raw_response));
    }
    let response: Value = serde_json::from_str(&raw_response)
        .map_err(|e| CliError::new("protocol", format!("Invalid v2 response: {e}")))?;
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(response.get("result").cloned().unwrap_or_else(|| json!({})));
    }
    if let Some(error) = response.get("error").and_then(Value::as_object) {
        let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
        let message = error.get("message").and_then(Value::as_str).unwrap_or("Unknown v2 error");
        let mut err = CliError::new(code, format_v2_error(error));
        if error.get("data").and_then(Value::as_object).and_then(|d| d.get("retryable")).and_then(Value::as_bool) == Some(true) {
            err.retryable = true;
        }
        return Err(err);
    }
    Err(CliError::new("protocol", "v2 request failed"))
}

pub fn raw(ctx: &Context, command: &str) -> Result<String> {
    if command.contains('\n') || command.contains('\r') {
        return Err(CliError::new("invalid_command", "Socket command must not contain newlines"));
    }
    let path = socket_path(ctx)?;
    let timeout = if ctx.timeout.is_zero() { DEFAULT_TIMEOUT } else { ctx.timeout };
    let deadline = Instant::now() + timeout;
    let mut stream = connect(&path, timeout)?;
    stream.set_read_timeout(Some(timeout)).ok();
    stream.set_write_timeout(Some(timeout)).ok();

    let password = resolve_password(ctx, &path);
    if let Some(password) = password {
        write_line(&mut stream, &wrap_command(&format!("auth {password}"), &path), deadline)?;
        let auth = read_response(&mut stream, deadline)?;
        if auth.starts_with("ERROR:") && !auth.contains("Unknown command 'auth'") {
            return Err(CliError::new("auth_failed", auth));
        }
    }
    let command = wrap_command(&automation_origin_command(command), &path);
    write_line(&mut stream, &command, deadline)?;
    let response = read_response(&mut stream, deadline)?;
    if response.starts_with("ERROR:") {
        return Err(CliError::new("socket_error", response));
    }
    Ok(response)
}

fn connect(path: &str, timeout: Duration) -> Result<WireStream> {
    if let Some((host, port)) = relay_endpoint(path) {
        let address: SocketAddr = format!("{host}:{port}").parse().map_err(|_| CliError::new("socket_path", "Invalid relay endpoint"))?;
        let mut stream = TcpStream::connect_timeout(&address, timeout).map_err(|e| CliError::new("connect", format!("Failed to connect to relay at {path}: {e}")))?;
        authenticate_relay(&mut stream, port, timeout)?;
        return Ok(WireStream::Tcp(stream));
    }
    let metadata = fs::metadata(path).map_err(|e| CliError::new("socket_missing", format!("Socket not found at {path}: {e}")))?;
    if !metadata.file_type().is_socket() {
        return Err(CliError::new("socket_type_conflict", format!("Path exists at {path} but is not a Unix socket")));
    }
    if metadata.uid() != unsafe { libc::getuid() } {
        return Err(CliError::new("socket_ownership_conflict", "Socket is not owned by the current user, refusing to connect"));
    }
    let stream = connect_unix(path, timeout)?;
    Ok(WireStream::Unix(stream))
}

fn connect_unix(path: &str, timeout: Duration) -> Result<UnixStream> {
    let bytes = path.as_bytes();
    if bytes.len() >= 104 { return Err(CliError::new("socket_path", "Unix socket path is too long")); }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 { return Err(CliError::new("connect", std::io::Error::last_os_error().to_string())); }
    let fail = |message: String| { unsafe { libc::close(fd); } Err(CliError::new("connect", message)) };
    let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if original_flags < 0 { return fail(std::io::Error::last_os_error().to_string()); }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 { return fail(std::io::Error::last_os_error().to_string()); }
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (index, byte) in bytes.iter().enumerate() { address.sun_path[index] = *byte as libc::c_char; }
    let address_len = (std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1) as libc::socklen_t;
    let result = unsafe { libc::connect(fd, &address as *const _ as *const libc::sockaddr, address_len) };
    if result < 0 && !matches!(std::io::Error::last_os_error().raw_os_error(), Some(code) if code == libc::EINPROGRESS || code == libc::EALREADY || code == libc::EAGAIN || code == libc::EWOULDBLOCK) {
        return fail(format!("Failed to connect to socket at {path}: {}", std::io::Error::last_os_error()));
    }
    if result < 0 {
        let mut pollfd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let millis = timeout.as_millis().min(i32::MAX as u128) as libc::c_int;
        let ready = unsafe { libc::poll(&mut pollfd, 1, millis) };
        if ready <= 0 { return fail(if ready == 0 { "Socket connection timed out".into() } else { std::io::Error::last_os_error().to_string() }); }
        let mut socket_error: libc::c_int = 0; let mut error_len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        if unsafe { libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_ERROR, &mut socket_error as *mut _ as *mut libc::c_void, &mut error_len) } < 0 || socket_error != 0 {
            return fail(format!("Failed to connect to socket at {path}: {}", std::io::Error::from_raw_os_error(if socket_error == 0 { libc::ECONNREFUSED } else { socket_error })));
        }
    }
    unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags); }
    Ok(unsafe { UnixStream::from_raw_fd(fd) })
}

enum WireStream { Unix(UnixStream), Tcp(TcpStream) }
impl Read for WireStream { fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> { match self { Self::Unix(s) => s.read(b), Self::Tcp(s) => s.read(b) } } }
impl Write for WireStream { fn write(&mut self, b: &[u8]) -> std::io::Result<usize> { match self { Self::Unix(s) => s.write(b), Self::Tcp(s) => s.write(b) } } fn flush(&mut self) -> std::io::Result<()> { match self { Self::Unix(s) => s.flush(), Self::Tcp(s) => s.flush() } } }
impl WireStream {
    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> { match self { Self::Unix(s) => s.set_read_timeout(timeout), Self::Tcp(s) => s.set_read_timeout(timeout) } }
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> { match self { Self::Unix(s) => s.set_write_timeout(timeout), Self::Tcp(s) => s.set_write_timeout(timeout) } }
}

fn write_line(stream: &mut WireStream, command: &str, deadline: Instant) -> Result<()> {
    let mut payload = command.as_bytes().to_vec(); payload.push(b'\n');
    let mut offset = 0;
    while offset < payload.len() {
        if Instant::now() >= deadline { return Err(CliError::new("timeout", "Command timed out")); }
        match stream.write(&payload[offset..]) {
            Ok(0) => return Err(CliError::new("socket_write", "Socket closed while writing")),
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(CliError::new("socket_write", format!("Failed to write to socket: {e}"))),
        }
    }
    stream.flush().map_err(|e| CliError::new("socket_write", e.to_string()))?;
    Ok(())
}

fn read_response(stream: &mut WireStream, deadline: Instant) -> Result<String> {
    let mut data = Vec::new(); let mut saw_newline = false;
    let mut buf = [0u8; 8192];
    loop {
        if Instant::now() >= deadline { return Err(CliError::new("timeout", "Command timed out")); }
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                data.extend_from_slice(&buf[..n]);
                if data.len() > MAX_RESPONSE_BYTES { return Err(CliError::new("protocol", "Socket response exceeded size limit")); }
                if data.contains(&b'\n') {
                    if !saw_newline { saw_newline = true; }
                    if is_complete_single_line(&data) { break; }
                    // The legacy protocol has multiline responses. Give the app a
                    // short idle window after the first line, matching Swift.
                    let idle_deadline = std::cmp::min(deadline, Instant::now() + MULTILINE_IDLE);
                    stream.set_read_timeout(Some(idle_deadline.saturating_duration_since(Instant::now()))).ok();
                    match stream.read(&mut buf) { Ok(n) if n > 0 => { data.extend_from_slice(&buf[..n]); continue; }, _ => break }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                if saw_newline { break; }
                return Err(CliError::new("timeout", "Command timed out"));
            }
            Err(e) => return Err(CliError::new("socket_read", format!("Socket read error: {e}"))),
        }
    }
    let text = String::from_utf8(data).map_err(|_| CliError::new("protocol", "Invalid UTF-8 socket response"))?;
    Ok(text.trim_end_matches(['\r', '\n']).to_string())
}

fn is_complete_single_line(data: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(data) else { return false; };
    let line = text.trim();
    line == "OK" || line == "PONG" || line.starts_with("OK ") || line.starts_with("ERROR:") || serde_json::from_str::<Value>(line).is_ok()
}

fn socket_path(ctx: &Context) -> Result<String> {
    if let Some(path) = ctx.socket.as_deref().filter(|v| !v.trim().is_empty()) { return Ok(path.trim().to_string()); }
    for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
        if let Ok(value) = env::var(key) { if !value.trim().is_empty() { return Ok(value.trim().to_string()); } }
    }
    let home = env::var_os("HOME").map(std::path::PathBuf::from);
    let mut candidates = Vec::new();
    if let Some(home) = home {
        candidates.push(home.join(".local/state/cmux/cmux.sock"));
        candidates.push(home.join(".local/state/cmux/last-socket"));
    }
    candidates.extend(["/tmp/cmux.sock", "/tmp/cmux-debug.sock"].iter().map(std::path::PathBuf::from));
    for candidate in &candidates {
        if candidate.file_name().and_then(|n| n.to_str()) == Some("last-socket") {
            if let Ok(value) = fs::read_to_string(candidate) { let value = value.trim(); if !value.is_empty() && Path::new(value).exists() { return Ok(value.to_string()); } }
        } else if candidate.exists() { return Ok(candidate.to_string_lossy().into_owned()); }
    }
    Ok(candidates.first().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| "/tmp/cmux.sock".into()))
}

fn resolve_password(ctx: &Context, socket_path: &str) -> Option<String> {
    if let Some(value) = ctx.password.as_deref().filter(|v| !v.trim().is_empty()) { return Some(value.to_string()); }
    if let Ok(value) = env::var("CMUX_SOCKET_PASSWORD") { if !value.trim().is_empty() { return Some(value); } }
    if let Ok(home) = env::var("HOME") {
        let path = Path::new(&home).join(".local/state/cmux/socket-control-password");
        if let Ok(value) = fs::read_to_string(path) { if !value.trim().is_empty() { return Some(value.trim_end_matches(['\r','\n']).to_string()); } }
    }
    // Keychain lookup is deliberately non-interactive. `security` is shipped
    // with macOS and gives the same legacy service/account fallback without
    // adding Security.framework to the CLI bundle.
    let scope = Path::new(socket_path).file_name().and_then(|v| v.to_str()).unwrap_or("");
    let mut services = vec!["com.cmuxterm.app.socket-control".to_string()];
    if let Some(tag) = env::var("CMUX_TAG").ok().filter(|v| !v.is_empty()) { services.insert(0, format!("com.cmuxterm.app.socket-control.{}", sanitize_scope(&tag))); }
    if let Some(raw) = scope.strip_prefix("cmux-debug-").and_then(|v| v.strip_suffix(".sock")) { services.insert(0, format!("com.cmuxterm.app.socket-control.{}", sanitize_scope(raw))); }
    for service in services {
        let Ok(output) = std::process::Command::new("security").args(["find-generic-password", "-s", &service, "-a", "local-socket-password", "-w"]).output() else { continue };
        if output.status.success() { let value = String::from_utf8_lossy(&output.stdout).trim().to_string(); if !value.is_empty() { return Some(value); } }
    }
    None
}

fn sanitize_scope(value: &str) -> String { value.chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c.to_ascii_lowercase() } else { '.' }).collect::<String>().split('.').filter(|p| !p.is_empty()).collect::<Vec<_>>().join(".") }

fn relay_endpoint(path: &str) -> Option<(&str, u16)> { let (host, port) = path.rsplit_once(':')?; if !matches!(host, "127.0.0.1" | "localhost") { return None; } Some(("127.0.0.1", port.parse().ok()?)) }

fn authenticate_relay(stream: &mut TcpStream, port: u16, timeout: Duration) -> Result<()> {
    stream.set_read_timeout(Some(timeout)).ok(); stream.set_write_timeout(Some(timeout)).ok();
    let (relay_id, token) = relay_credentials(port)?;
    let mut challenge = String::new();
    std::io::BufReader::new(stream.try_clone().map_err(|e| CliError::new("relay", e.to_string()))?)
        .read_line(&mut challenge)
        .map_err(|e| CliError::new("relay_auth", e.to_string()))?;
    let line = challenge.trim_end_matches(['\r', '\n']);
    let challenge: Value = serde_json::from_str(line).map_err(|_| CliError::new("relay_auth", "Invalid relay authentication challenge"))?;
    if challenge.get("protocol").and_then(Value::as_str) != Some("cmux-relay-auth") || challenge.get("relay_id").and_then(Value::as_str) != Some(relay_id.as_str()) { return Err(CliError::new("relay_auth", "Invalid relay authentication challenge")); }
    let nonce = challenge.get("nonce").and_then(Value::as_str).unwrap_or(""); let version = challenge.get("version").and_then(Value::as_i64).unwrap_or(0);
    let mac = hmac_sha256(&token, format!("relay_id={relay_id}\nnonce={nonce}\nversion={version}").as_bytes());
    let payload = json!({"relay_id": relay_id, "mac": hex(&mac)}).to_string() + "\n"; stream.write_all(payload.as_bytes()).map_err(|e| CliError::new("relay_auth", e.to_string()))?;
    let mut response = String::new();
    std::io::BufReader::new(stream.try_clone().map_err(|e| CliError::new("relay", e.to_string()))?)
        .read_line(&mut response)
        .map_err(|e| CliError::new("relay_auth", e.to_string()))?;
    let response: Value = serde_json::from_str(response.trim()).map_err(|_| CliError::new("relay_auth", "Invalid relay authentication response"))?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) { return Err(CliError::new("relay_auth", "Relay authentication failed")); }
    Ok(())
}

fn relay_credentials(port: u16) -> Result<(String, Vec<u8>)> {
    if let (Ok(id), Ok(token)) = (env::var("CMUX_RELAY_ID"), env::var("CMUX_RELAY_TOKEN")) { if let Some(bytes) = decode_hex(&token) { return Ok((id, bytes)); } }
    let home = env::var("HOME").map_err(|_| CliError::new("relay_auth", "Missing HOME for relay auth metadata"))?;
    let value: Value = serde_json::from_slice(&fs::read(Path::new(&home).join(format!(".cmux/relay/{port}.auth"))).map_err(|_| CliError::new("relay_auth", "Missing relay auth metadata"))?).map_err(|_| CliError::new("relay_auth", "Invalid relay auth metadata"))?;
    let id = value.get("relay_id").and_then(Value::as_str).ok_or_else(|| CliError::new("relay_auth", "Missing relay id"))?; let token = value.get("relay_token").and_then(Value::as_str).and_then(decode_hex).ok_or_else(|| CliError::new("relay_auth", "Missing relay token"))?; Ok((id.to_string(), token))
}

fn decode_hex(value: &str) -> Option<Vec<u8>> { if value.len() % 2 != 0 { return None; } (0..value.len()).step_by(2).map(|i| u8::from_str_radix(&value[i..i+2], 16).ok()).collect() }
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|v| format!("{v:02x}")).collect() }
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] { let mut key = key.to_vec(); if key.len() > 64 { key = Sha256::digest(&key).to_vec(); } key.resize(64, 0); let mut inner = vec![0x36; 64]; let mut outer = vec![0x5c; 64]; for i in 0..64 { inner[i] ^= key[i]; outer[i] ^= key[i]; } let inner_hash = Sha256::digest([inner, message.to_vec()].concat()); let result = Sha256::digest([outer, inner_hash.to_vec()].concat()); result.into() }
fn automation_origin(rule_id: &str) -> Value { let chain = env::var("CMUX_AUTOMATION_CHAIN").ok().and_then(|raw| serde_json::from_str::<Value>(&raw).ok()).or_else(|| Some(Value::Array(raw_chain(rule_id).into_iter().map(Value::String).collect()))).unwrap_or_else(|| json!([rule_id])); json!({"rule_id": rule_id, "chain": chain}) }
fn raw_chain(rule_id: &str) -> Vec<String> { env::var("CMUX_AUTOMATION_CHAIN").unwrap_or_else(|_| rule_id.to_string()).split(',').filter(|v| !v.is_empty()).map(ToOwned::to_owned).collect() }
fn automation_origin_command(command: &str) -> String { if command.starts_with("__cmux_automation_origin ") { return command.to_string(); } let Ok(rule) = env::var("CMUX_AUTOMATION_RULE_ID") else { return command.to_string(); }; if rule.is_empty() { return command.to_string(); } let encoded = base64::engine::general_purpose::STANDARD.encode(automation_origin(&rule).to_string()); format!("__cmux_automation_origin {encoded} {command}") }
fn wrap_command(command: &str, path: &str) -> String { if relay_endpoint(path).is_some() { return command.to_string(); } let Ok(capability) = env::var("CMUX_SOCKET_CAPABILITY") else { return command.to_string(); }; if capability.trim().is_empty() || capability.chars().any(char::is_whitespace) { return command.to_string(); } format!("_cmux_capability_v1 {capability} {command}") }
fn format_v2_error(error: &serde_json::Map<String, Value>) -> String { let code = error.get("code").and_then(Value::as_str).unwrap_or("error"); let message = error.get("message").and_then(Value::as_str).unwrap_or("Unknown v2 error"); let mut result = if message.contains('\n') { format!("{code}:\n{message}") } else { format!("{code}: {message}") }; for (label, key) in [("Reason", "reason"), ("What to do", "action")] { if let Some(value) = error.get(key).and_then(Value::as_str).filter(|v| !v.trim().is_empty()) { result.push_str(&format!("\n\n{label}:\n  {}", value.replace('\n', "\n  "))); } } result }
