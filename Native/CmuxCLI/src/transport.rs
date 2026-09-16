//! Shared newline-framed control socket transport. Every request uses an owned
//! connection and one monotonic deadline; a failed request can never leave a
//! delayed reply for a subsequent operation.

use crate::{CliError, Context, Result};
use base64::Engine;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::CStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::net::{SocketAddr, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);
const MULTILINE_IDLE: Duration = Duration::from_millis(120);
const STREAM_IDLE: Duration = Duration::from_secs(45);
const CONNECT_RETRY: Duration = Duration::from_millis(350);
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_STREAM_FRAME: usize = 4 * 1024 * 1024;
const MAX_RELAY_FRAME: usize = 16 * 1024;
const MAX_MARKER_BYTES: u64 = 4096;
type Environment = HashMap<String, String>;

pub fn rpc(ctx: &Context, method: &str, params: Value) -> Result<Value> {
    let environment = env::vars().collect();
    let request = request(method, params, &environment)?;
    let response = raw_with_environment(ctx, &request.to_string(), &environment)?;
    decode_response(&response)
}

pub fn raw(ctx: &Context, command: &str) -> Result<String> {
    raw_with_environment(ctx, command, &env::vars().collect())
}

/// Write a legacy command without waiting for its reply. Authentication still
/// completes before the command is sent. Delivery is never retried after write.
pub fn send_one_way(ctx: &Context, command: &str, timeout: Duration) -> Result<()> {
    validate_command(command)?;
    let environment = env::vars().collect();
    let deadline = deadline_after(timeout)?;
    let (mut socket, wire) = prepare(ctx, &environment, Some(deadline))?;
    socket.write_line(&wire.command(command, &environment), deadline)
}

pub fn rpc_one_way(ctx: &Context, method: &str, params: Value, timeout: Duration) -> Result<()> {
    let environment = env::vars().collect();
    let request = request(method, params, &environment)?;
    let deadline = deadline_after(timeout)?;
    let (mut socket, wire) = prepare(ctx, &environment, Some(deadline))?;
    socket.write_line(&wire.command(&request.to_string(), &environment), deadline)
}

/// Stream complete newline-delimited v2 frames. Return `false` from `on_line`
/// to close the stream successfully. Without an overall deadline, the Swift
/// protocol's 45-second idle timeout applies independently to each frame.
pub fn stream_v2(
    ctx: &Context,
    method: &str,
    params: Value,
    deadline: Option<Instant>,
    mut on_line: impl FnMut(&str) -> Result<bool>,
) -> Result<()> {
    let environment = env::vars().collect();
    let request = request(method, params, &environment)?;
    let (mut socket, wire) = prepare(ctx, &environment, deadline)?;
    let write_deadline = deadline.unwrap_or(deadline_after(response_timeout(ctx, &environment))?);
    socket.write_line(
        &wire.command(&request.to_string(), &environment),
        write_deadline,
    )?;
    loop {
        let frame_deadline = deadline.unwrap_or(deadline_after(STREAM_IDLE)?);
        let frame = socket.read_line(frame_deadline, MAX_STREAM_FRAME, "Event stream")?;
        if !on_line(frame.trim())? {
            return Ok(());
        }
    }
}

fn raw_with_environment(ctx: &Context, command: &str, environment: &Environment) -> Result<String> {
    validate_command(command)?;
    let deadline = deadline_after(response_timeout(ctx, environment))?;
    let (mut socket, wire) = prepare(ctx, environment, Some(deadline))?;
    socket.write_line(&wire.command(command, environment), deadline)?;
    let response = socket.read_response(deadline)?;
    if response.starts_with("ERROR:") {
        return Err(CliError::new("socket_error", response));
    }
    Ok(response)
}

fn validate_command(command: &str) -> Result<()> {
    if command.contains(['\n', '\r', '\0']) {
        return Err(CliError::new(
            "invalid_command",
            "Socket command must not contain newlines or NUL",
        ));
    }
    Ok(())
}

fn validate_password(password: Option<&str>) -> Result<()> {
    if password.is_some_and(|value| value.contains(['\r', '\n', '\0'])) {
        return Err(CliError::new(
            "invalid_password",
            "Socket password must not contain newlines or NUL",
        ));
    }
    Ok(())
}

fn capability(environment: &Environment) -> Result<Option<String>> {
    match environment.get("CMUX_SOCKET_CAPABILITY") {
        None => Ok(None),
        Some(value)
            if value.is_empty() || value.chars().any(|c| c.is_whitespace() || c.is_control()) =>
        {
            Err(CliError::new(
                "invalid_capability",
                "CMUX_SOCKET_CAPABILITY must be one nonempty token",
            ))
        }
        Some(value) => Ok(Some(value.clone())),
    }
}

struct WireOptions {
    capability: Option<String>,
    relay: bool,
}
impl WireOptions {
    fn wrap(&self, command: &str) -> String {
        if !self.relay {
            if let Some(capability) = &self.capability {
                return format!("_cmux_capability_v1 {capability} {command}");
            }
        }
        command.to_string()
    }
    fn command(&self, command: &str, environment: &Environment) -> String {
        self.wrap(&automation_origin_command(command, environment))
    }
}

fn prepare(
    ctx: &Context,
    environment: &Environment,
    overall: Option<Instant>,
) -> Result<(Socket, WireOptions)> {
    // Validate credentials before discovery, which itself performs connect
    // probes. A malformed credential must never open any socket.
    let capability = capability(environment)?;
    validate_password(ctx.password.as_deref())?;
    validate_password(environment.get("CMUX_SOCKET_PASSWORD").map(String::as_str))?;
    let home = account_home();
    let password = password_without_keychain(ctx, environment, home.as_deref())?;
    let setup_deadline = overall.unwrap_or(deadline_after(response_timeout(ctx, environment))?);
    let path = socket_path_with(ctx, environment, home.as_deref(), setup_deadline)?;
    let password = match password {
        Some(password) => Some(password),
        None => keychain_password(&path, environment),
    };
    validate_password(password.as_deref())?;
    remaining(setup_deadline)?;
    let wire = WireOptions {
        capability,
        relay: relay_endpoint(&path).is_some(),
    };
    let mut socket = connect(&path, setup_deadline, environment)?;
    if let Some(password) = password {
        socket.write_line(
            &wire.command(&format!("auth {password}"), environment),
            setup_deadline,
        )?;
        let response = socket.read_response(setup_deadline)?;
        if response.starts_with("ERROR:") && !response.contains("Unknown command 'auth'") {
            // Authentication errors must not echo submitted credentials even if
            // a malformed peer reflects the request.
            return Err(CliError::new("auth_failed", "Socket authentication failed"));
        }
    }
    Ok((socket, wire))
}

fn response_timeout(ctx: &Context, environment: &Environment) -> Duration {
    // Explicit Context timeouts win. The default preserves the legacy hook
    // environment budget until the shared parser supplies an override.
    if ctx.timeout != DEFAULT_TIMEOUT && !ctx.timeout.is_zero() {
        return ctx.timeout;
    }
    environment
        .get("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC")
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|n| n.is_finite() && *n > 0.0)
        .and_then(|n| Duration::try_from_secs_f64(n).ok())
        .unwrap_or(DEFAULT_TIMEOUT)
}
fn deadline_after(timeout: Duration) -> Result<Instant> {
    Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| CliError::usage("Timeout is too large"))
}
fn remaining(deadline: Instant) -> Result<Duration> {
    let duration = deadline.saturating_duration_since(Instant::now());
    if duration.is_zero() {
        Err(CliError::new("timeout", "Command timed out"))
    } else {
        Ok(duration)
    }
}

struct Socket {
    fd: OwnedFd,
    buffered: Vec<u8>,
}
impl Socket {
    fn from_fd(fd: OwnedFd) -> Result<Self> {
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return Err(CliError::new(
                "socket_setup",
                io::Error::last_os_error().to_string(),
            ));
        }
        if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(CliError::new(
                "socket_setup",
                io::Error::last_os_error().to_string(),
            ));
        }
        #[cfg(target_os = "macos")]
        {
            let one: libc::c_int = 1;
            if unsafe {
                libc::setsockopt(
                    fd.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    &one as *const _ as *const libc::c_void,
                    std::mem::size_of_val(&one) as libc::socklen_t,
                )
            } < 0
            {
                return Err(CliError::new(
                    "socket_setup",
                    "Failed to disable SIGPIPE on socket",
                ));
            }
        }
        Ok(Self {
            fd,
            buffered: Vec::new(),
        })
    }
    fn wait(&self, events: libc::c_short, deadline: Instant) -> Result<()> {
        loop {
            let budget = remaining(deadline)?;
            let millis = budget
                .as_millis()
                .saturating_add(u128::from(budget.subsec_nanos() % 1_000_000 != 0))
                .min(i32::MAX as u128) as i32;
            let mut descriptor = libc::pollfd {
                fd: self.fd.as_raw_fd(),
                events,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut descriptor, 1, millis) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(CliError::new("socket_io", error.to_string()));
            }
            if ready == 0 {
                return Err(CliError::new("timeout", "Command timed out"));
            }
            if descriptor.revents & libc::POLLNVAL != 0 {
                return Err(CliError::new("socket_io", "Invalid socket descriptor"));
            }
            if descriptor.revents & (events | libc::POLLERR | libc::POLLHUP) != 0 {
                return Ok(());
            }
        }
    }
    fn write_line(&mut self, command: &str, deadline: Instant) -> Result<()> {
        let mut data = Vec::with_capacity(command.len() + 1);
        data.extend_from_slice(command.as_bytes());
        data.push(b'\n');
        let mut offset = 0;
        while offset < data.len() {
            self.wait(libc::POLLOUT, deadline)?;
            #[cfg(target_os = "linux")]
            let flags = libc::MSG_NOSIGNAL;
            #[cfg(not(target_os = "linux"))]
            let flags = 0;
            let count = unsafe {
                libc::send(
                    self.fd.as_raw_fd(),
                    data[offset..].as_ptr().cast(),
                    data.len() - offset,
                    flags,
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) {
                    continue;
                }
                return Err(CliError::new(
                    "socket_write",
                    format!("Failed to write to socket: {error}"),
                ));
            }
            if count == 0 {
                return Err(CliError::new("socket_write", "Socket closed while writing"));
            }
            offset += count as usize;
        }
        Ok(())
    }
    fn read_chunk(&mut self, deadline: Instant) -> Result<usize> {
        loop {
            self.wait(libc::POLLIN, deadline)?;
            let mut buffer = [0u8; 8192];
            let count = unsafe {
                libc::read(
                    self.fd.as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) {
                    continue;
                }
                return Err(CliError::new(
                    "socket_read",
                    format!("Socket read error: {error}"),
                ));
            }
            self.buffered.extend_from_slice(&buffer[..count as usize]);
            return Ok(count as usize);
        }
    }
    fn read_line(&mut self, deadline: Instant, max_bytes: usize, label: &str) -> Result<String> {
        loop {
            if let Some(newline) = self.buffered.iter().position(|b| *b == b'\n') {
                if newline >= max_bytes {
                    return Err(CliError::new(
                        "protocol",
                        format!("{label} frame exceeded {max_bytes} bytes"),
                    ));
                }
                let line =
                    String::from_utf8(self.buffered.drain(..=newline).collect()).map_err(|_| {
                        CliError::new("protocol", format!("Invalid UTF-8 {label} frame"))
                    })?;
                return Ok(line.trim_end_matches(['\r', '\n']).to_string());
            }
            if self.buffered.len() >= max_bytes {
                return Err(CliError::new(
                    "protocol",
                    format!("{label} frame exceeded {max_bytes} bytes"),
                ));
            }
            if self.read_chunk(deadline)? == 0 {
                return Err(CliError::new(
                    "stream_closed",
                    format!("{label} closed before a complete frame"),
                ));
            }
        }
    }
    fn read_response(&mut self, deadline: Instant) -> Result<String> {
        loop {
            if self.buffered.len() > MAX_RESPONSE_BYTES {
                return Err(CliError::new(
                    "protocol",
                    "Socket response exceeded size limit",
                ));
            }
            let saw_newline = self.buffered.contains(&b'\n');
            if saw_newline && is_complete_single_line(&self.buffered) {
                break;
            }
            let next_deadline = if saw_newline {
                deadline.min(deadline_after(MULTILINE_IDLE)?)
            } else {
                deadline
            };
            match self.read_chunk(next_deadline) {
                Ok(0) if self.buffered.is_empty() => {
                    return Err(CliError::new("socket_closed", "Socket closed before reply"));
                }
                Ok(0) if !saw_newline => {
                    return Err(CliError::new(
                        "protocol",
                        "Socket closed before complete reply",
                    ));
                }
                Ok(0) => break,
                Ok(_) => {}
                Err(error)
                    if error.code == "timeout" && saw_newline && Instant::now() < deadline =>
                {
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        let mut response = String::from_utf8(std::mem::take(&mut self.buffered))
            .map_err(|_| CliError::new("protocol", "Invalid UTF-8 socket response"))?;
        if response.ends_with('\n') {
            response.pop();
        }
        Ok(response)
    }
}

fn connect(path: &str, deadline: Instant, environment: &Environment) -> Result<Socket> {
    if let Some(port) = relay_endpoint(path) {
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let stream = TcpStream::connect_timeout(&address, remaining(deadline)?).map_err(|e| {
            CliError::new(
                "connect",
                format!("Failed to connect to relay at {path}: {e}"),
            )
        })?;
        let mut socket = Socket::from_fd(stream.into())?;
        let credentials = relay_credentials(port, environment)?;
        authenticate_relay(&mut socket, &credentials, deadline)?;
        return Ok(socket);
    }
    inspect_explicit_socket(path)?;
    let retry_deadline = deadline.min(deadline_after(CONNECT_RETRY)?);
    loop {
        match connect_unix(path, deadline) {
            Ok(socket) => return Ok(socket),
            Err(error)
                if matches!(error.raw_os_error(), Some(code) if code == libc::ECONNREFUSED || code == libc::ENOENT || code == libc::EAGAIN || code == libc::EWOULDBLOCK)
                    && Instant::now() < retry_deadline =>
            {
                std::thread::sleep(
                    Duration::from_millis(25)
                        .min(retry_deadline.saturating_duration_since(Instant::now())),
                );
            }
            Err(error) => {
                return Err(CliError::new(
                    if error.kind() == io::ErrorKind::TimedOut {
                        "timeout"
                    } else {
                        "connect"
                    },
                    format!("Failed to connect to socket at {path}: {error}"),
                ));
            }
        }
    }
}
fn inspect_explicit_socket(path: &str) -> Result<()> {
    let metadata = fs::metadata(path)
        .map_err(|_| CliError::new("socket_missing", format!("Socket not found at {path}")))?;
    if !metadata.file_type().is_socket() {
        return Err(CliError::new(
            "socket_type_conflict",
            format!("Path exists at {path} but is not a Unix socket"),
        ));
    }
    if metadata.uid() != unsafe { libc::getuid() } {
        return Err(CliError::new(
            "socket_ownership_conflict",
            format!("Socket at {path} is not owned by the current user, refusing to connect"),
        ));
    }
    Ok(())
}
fn connect_unix(path: &str, deadline: Instant) -> io::Result<Socket> {
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    let bytes = path.as_bytes();
    if bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unix socket path is too long or contains NUL",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (target, byte) in address.sun_path.iter_mut().zip(bytes) {
        *target = *byte as libc::c_char;
    }
    #[cfg(target_os = "macos")]
    {
        address.sun_len = std::mem::size_of_val(&address) as u8;
    }
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let socket = Socket::from_fd(unsafe { OwnedFd::from_raw_fd(raw) }).map_err(io::Error::other)?;
    let result = unsafe {
        libc::connect(
            socket.fd.as_raw_fd(),
            &address as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&address) as libc::socklen_t,
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(code) if code == libc::EINPROGRESS || code == libc::EALREADY || code == libc::EAGAIN || code == libc::EWOULDBLOCK)
        {
            return Err(error);
        }
        socket.wait(libc::POLLOUT, deadline).map_err(|error| {
            io::Error::new(
                if error.code == "timeout" {
                    io::ErrorKind::TimedOut
                } else {
                    io::ErrorKind::Other
                },
                error,
            )
        })?;
        let mut error: libc::c_int = 0;
        let mut size = std::mem::size_of_val(&error) as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                socket.fd.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                &mut error as *mut _ as *mut libc::c_void,
                &mut size,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        if error != 0 {
            return Err(io::Error::from_raw_os_error(error));
        }
    }
    Ok(socket)
}

/// Resolve an explicit socket without probing/rerouting, or discover one live,
/// current-user-owned implicit socket in the same order as Swift's resolver.
pub fn socket_path(ctx: &Context) -> Result<String> {
    socket_path_with(
        ctx,
        &env::vars().collect(),
        account_home().as_deref(),
        deadline_after(ctx.timeout.max(Duration::from_millis(1)))?,
    )
}

/// Exposes the resolved socket path to the bundled Feed terminal launcher.
pub fn resolved_socket_path(ctx: &Context) -> Result<String> {
    socket_path(ctx)
}

/// Resolves the same password sources used by the socket transport without
/// opening a connection. The Feed launcher uses this only to pass auth to its
/// child process; malformed credentials fail before any child starts.
pub fn resolved_password(ctx: &Context, path: &str) -> Result<Option<String>> {
    let environment: Environment = env::vars().collect();
    let home = account_home();
    let password = password_without_keychain(ctx, &environment, home.as_deref())?;
    let password = match password {
        Some(value) => Some(value),
        None => keychain_password(path, &environment),
    };
    validate_password(password.as_deref())?;
    Ok(password)
}
fn socket_path_with(
    ctx: &Context,
    environment: &Environment,
    home: Option<&Path>,
    deadline: Instant,
) -> Result<String> {
    if let Some(path) = ctx.socket.as_deref() {
        if path.trim().is_empty() {
            return Err(CliError::usage("--socket requires a nonempty path"));
        }
        return Ok(path.to_string());
    }
    let preferred = normalized(environment.get("CMUX_SOCKET_PATH").map(String::as_str));
    let legacy = normalized(environment.get("CMUX_SOCKET").map(String::as_str));
    if let (Some(preferred), Some(legacy)) = (preferred, legacy) {
        if preferred != legacy {
            return Err(CliError::new(
                "socket_conflict",
                "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET.",
            ));
        }
    }
    if let Some(path) = preferred.or(legacy) {
        return Ok(path.to_string());
    }
    let variant = Variant::resolve(
        current_bundle_identifier(environment).as_deref(),
        environment,
    );
    let uid = unsafe { libc::getuid() };
    let candidates = discovery_candidates(&variant, home, uid);
    for path in &candidates {
        remaining(deadline)?;
        if owned_socket(path, uid)
            && connect_unix(
                path,
                deadline.min(deadline_after(Duration::from_millis(150))?),
            )
            .is_ok()
        {
            let requested = variant.socket_path(home);
            if !paths_match(&requested, path) {
                eprintln!("cmux: default socket {requested} is unavailable; using {path}.");
            }
            return Ok(path.clone());
        }
    }
    Err(CliError::new(
        "socket_missing",
        format!(
            "No live cmux socket found. Tried:\n{}",
            candidates
                .iter()
                .map(|p| format!("  {p}"))
                .collect::<Vec<_>>()
                .join("\n")
        ),
    ))
}

/// Startup callers can retry discovery while the app installs its listener.
/// Explicit targets stay pinned; permanent ownership/type conflicts stop at once.
pub fn wait_for_connectable_socket(ctx: &Context, timeout: Duration) -> Result<String> {
    let deadline = deadline_after(timeout)?;
    let environment = env::vars().collect();
    loop {
        let result = socket_path_with(ctx, &environment, account_home().as_deref(), deadline)
            .and_then(|path| connect(&path, deadline, &environment).map(|_| path));
        match result {
            Ok(path) => return Ok(path),
            Err(error)
                if matches!(
                    error.code.as_str(),
                    "socket_missing" | "connect" | "timeout"
                ) =>
            {
                if Instant::now() >= deadline {
                    return Err(CliError::new(
                        "startup_timeout",
                        "cmux app did not start in time (socket unavailable)",
                    ));
                }
                std::thread::sleep(
                    Duration::from_millis(25)
                        .min(deadline.saturating_duration_since(Instant::now())),
                );
            }
            Err(error) => return Err(error),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Variant {
    Stable,
    Nightly(Option<String>),
    Staging(Option<String>),
    Dev(Option<String>),
}
impl Variant {
    fn resolve(bundle: Option<&str>, environment: &Environment) -> Self {
        let bundle = bundle.unwrap_or("com.cmuxterm.app").trim();
        for (prefix, kind) in [
            ("com.cmuxterm.app.nightly", 0),
            ("com.cmuxterm.app.staging", 1),
            ("com.cmuxterm.app.debug", 2),
        ] {
            let slug = if bundle == prefix {
                if kind == 2 {
                    environment.get("CMUX_TAG").and_then(|s| socket_slug(s))
                } else {
                    None
                }
            } else if let Some(suffix) = bundle.strip_prefix(&format!("{prefix}.")) {
                socket_slug(suffix)
            } else {
                continue;
            };
            return match kind {
                0 => Self::Nightly(slug),
                1 => Self::Staging(slug),
                _ => Self::Dev(slug),
            };
        }
        Self::Stable
    }
    fn name(&self) -> String {
        match self {
            Self::Stable => String::new(),
            Self::Nightly(slug) => variant_name("nightly", slug),
            Self::Staging(slug) => variant_name("staging", slug),
            Self::Dev(slug) => variant_name("dev", slug),
        }
    }
    fn socket_path(&self, home: Option<&Path>) -> String {
        match self {
            Self::Stable => state_directory(home)
                .map(|p| p.join("cmux.sock").to_string_lossy().into_owned())
                .unwrap_or_else(|| "/tmp/cmux.sock".into()),
            Self::Nightly(slug) => format!("/tmp/cmux-{}.sock", variant_name("nightly", slug)),
            Self::Staging(slug) => format!("/tmp/cmux-{}.sock", variant_name("staging", slug)),
            Self::Dev(slug) => format!("/tmp/cmux-{}.sock", variant_name("debug", slug)),
        }
    }
    fn markers(&self, home: Option<&Path>) -> Vec<PathBuf> {
        let name = self.name();
        let file = if name.is_empty() {
            "last-socket-path".into()
        } else {
            format!("{name}-last-socket-path")
        };
        let mut markers = Vec::new();
        if let Some(state) = state_directory(home) {
            markers.push(state.join(&file));
        }
        markers.push(Path::new("/tmp").join(format!("cmux-{file}")));
        markers
    }
}
fn variant_name(prefix: &str, slug: &Option<String>) -> String {
    slug.as_ref()
        .map(|s| format!("{prefix}-{s}"))
        .unwrap_or_else(|| prefix.to_string())
}
fn socket_slug(raw: &str) -> Option<String> {
    let mut value = String::new();
    for c in raw.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            value.push(c);
        } else if !value.ends_with('-') {
            value.push('-');
        }
    }
    normalized(Some(value.trim_matches('-'))).map(str::to_string)
}
fn discovery_candidates(variant: &Variant, home: Option<&Path>, uid: u32) -> Vec<String> {
    let mut paths = vec![variant.socket_path(home), Variant::Stable.socket_path(home)];
    for marker in variant
        .markers(home)
        .into_iter()
        .chain(Variant::Stable.markers(home))
    {
        if let Some(value) = bounded_marker(&marker, uid) {
            paths.push(value);
        }
    }
    paths.push("/tmp/cmux.sock".into());
    if let Some(state) = state_directory(home) {
        paths.push(
            state
                .join(format!("cmux-{uid}.sock"))
                .to_string_lossy()
                .into_owned(),
        );
    }
    paths.push(format!("/tmp/cmux-{uid}.sock"));
    let mut seen = HashSet::new();
    paths.retain(|path| !path.is_empty() && seen.insert(path.clone()));
    paths
}
fn owned_socket(path: &str, uid: u32) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket() && m.uid() == uid)
}
fn bounded_marker(path: &Path, uid: u32) -> Option<String> {
    // O_NOFOLLOW plus fstat binds validation to the opened inode. Checking only
    // lstat before open would allow a marker to be replaced with a symlink.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.uid() != uid || meta.nlink() != 1 || meta.len() > MAX_MARKER_BYTES {
        return None;
    }
    let mut value = String::new();
    file.take(MAX_MARKER_BYTES + 1)
        .read_to_string(&mut value)
        .ok()?;
    if value.len() as u64 > MAX_MARKER_BYTES || value.contains('\0') {
        return None;
    }
    normalized(Some(&value)).map(str::to_string)
}
fn paths_match(a: &str, b: &str) -> bool {
    let normalize = |value: &str| {
        fs::canonicalize(value)
            .unwrap_or_else(|_| PathBuf::from(value))
            .to_string_lossy()
            .replace("/private/tmp/", "/tmp/")
            .to_lowercase()
    };
    normalize(a) == normalize(b)
}
fn state_directory(home: Option<&Path>) -> Option<PathBuf> {
    home.map(|home| home.join(".local/state/cmux"))
}
fn account_home() -> Option<PathBuf> {
    // Match FileManager.homeDirectoryForCurrentUser, which does not trust a
    // shell's HOME override for the app's control-plane state.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16384];
    if unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    } == 0
        && !result.is_null()
        && !entry.pw_dir.is_null()
    {
        return Some(PathBuf::from(
            unsafe { CStr::from_ptr(entry.pw_dir) }
                .to_string_lossy()
                .as_ref(),
        ));
    }
    None
}
fn current_bundle_identifier(environment: &Environment) -> Option<String> {
    #[cfg(target_os = "macos")]
    if let Ok(executable) = env::current_exe() {
        for parent in executable.ancestors() {
            if parent.extension().and_then(|s| s.to_str()) == Some("app") {
                if let Some(bundle) = macos::bundle_identifier(parent) {
                    return Some(bundle);
                }
            }
        }
    }
    normalized(environment.get("CMUX_BUNDLE_ID").map(String::as_str)).map(str::to_string)
}
fn normalized(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|s| !s.is_empty())
}

fn password_without_keychain(
    ctx: &Context,
    environment: &Environment,
    home: Option<&Path>,
) -> Result<Option<String>> {
    for value in [
        ctx.password.as_deref(),
        environment.get("CMUX_SOCKET_PASSWORD").map(String::as_str),
    ]
    .into_iter()
    .flatten()
    {
        validate_password(Some(value))?;
        if !value.is_empty() {
            return Ok(Some(value.to_string()));
        }
    }
    if let Some(path) = state_directory(home).map(|p| p.join("socket-control-password")) {
        if let Ok(value) = fs::read_to_string(path) {
            // A saved text file may contain a terminal newline, as in Swift.
            let value = value.trim_matches(['\r', '\n']);
            validate_password(Some(value))?;
            if !value.is_empty() {
                return Ok(Some(value.to_string()));
            }
        }
    }
    Ok(None)
}
fn keychain_services(path: &str, environment: &Environment) -> Vec<String> {
    let base = "com.cmuxterm.app.socket-control";
    let filename = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let scope = normalized(environment.get("CMUX_TAG").map(String::as_str))
        .map(sanitize_scope)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            ["cmux-debug-", "cmux-"].iter().find_map(|prefix| {
                filename
                    .strip_prefix(prefix)
                    .and_then(|s| s.strip_suffix(".sock"))
                    .map(sanitize_scope)
                    .filter(|s| !s.is_empty())
            })
        });
    let mut services = Vec::new();
    if let Some(scope) = scope {
        services.push(format!("{base}.{scope}"));
    }
    services.push(base.into());
    services
}
fn sanitize_scope(raw: &str) -> String {
    raw.to_lowercase()
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '.'
            }
        })
        .collect::<String>()
        .split('.')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(".")
}
fn keychain_password(path: &str, environment: &Environment) -> Option<String> {
    #[cfg(target_os = "macos")]
    for service in keychain_services(path, environment) {
        if let Some(password) = macos::password(&service) {
            return Some(password);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (path, environment);
    None
}

struct RelayCredentials {
    id: String,
    token: Vec<u8>,
}
fn relay_endpoint(raw: &str) -> Option<u16> {
    let (host, port) = raw.trim().split_once(':')?;
    if !host.eq_ignore_ascii_case("127.0.0.1") && !host.eq_ignore_ascii_case("localhost") {
        return None;
    }
    port.parse::<u16>().ok().filter(|p| *p > 0)
}
fn relay_credentials(port: u16, environment: &Environment) -> Result<RelayCredentials> {
    if let (Some(id), Some(token)) = (
        normalized(environment.get("CMUX_RELAY_ID").map(String::as_str)),
        normalized(environment.get("CMUX_RELAY_TOKEN").map(String::as_str)),
    ) {
        if let Some(token) = decode_hex(token) {
            return Ok(RelayCredentials {
                id: id.into(),
                token,
            });
        }
    }
    let home = environment
        .get("HOME")
        .map(PathBuf::from)
        .or_else(account_home)
        .ok_or_else(|| {
            CliError::new(
                "relay_auth",
                "Missing home directory for relay auth metadata",
            )
        })?;
    let file = File::open(home.join(format!(".cmux/relay/{port}.auth")))
        .map_err(|_| CliError::new("relay_auth", "Missing relay auth metadata"))?;
    let mut bytes = Vec::new();
    file.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 64 * 1024 {
        return Err(CliError::new("relay_auth", "Invalid relay auth metadata"));
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| CliError::new("relay_auth", "Invalid relay auth metadata"))?;
    let id = normalized(value.get("relay_id").and_then(Value::as_str))
        .ok_or_else(|| CliError::new("relay_auth", "Missing relay id"))?;
    let token = value
        .get("relay_token")
        .and_then(Value::as_str)
        .and_then(decode_hex)
        .ok_or_else(|| CliError::new("relay_auth", "Missing relay token"))?;
    Ok(RelayCredentials {
        id: id.into(),
        token,
    })
}
fn authenticate_relay(
    socket: &mut Socket,
    credentials: &RelayCredentials,
    deadline: Instant,
) -> Result<()> {
    let line = socket.read_line(deadline, MAX_RELAY_FRAME, "Relay authentication")?;
    let challenge: Value = serde_json::from_str(&line)
        .map_err(|_| CliError::new("relay_auth", "Invalid relay authentication challenge"))?;
    let nonce = challenge
        .get("nonce")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let version = challenge.get("version").and_then(Value::as_i64);
    if challenge.get("protocol").and_then(Value::as_str) != Some("cmux-relay-auth")
        || challenge.get("relay_id").and_then(Value::as_str) != Some(credentials.id.as_str())
        || nonce.is_none()
        || version.is_none()
    {
        return Err(CliError::new(
            "relay_auth",
            "Invalid relay authentication challenge",
        ));
    }
    let auth = format!(
        "relay_id={}\nnonce={}\nversion={}",
        credentials.id,
        nonce.unwrap(),
        version.unwrap()
    );
    let mac = hmac_sha256(&credentials.token, auth.as_bytes());
    socket.write_line(
        &json!({"relay_id": credentials.id, "mac": hex(&mac)}).to_string(),
        deadline,
    )?;
    let line = socket.read_line(deadline, MAX_RELAY_FRAME, "Relay authentication")?;
    let response: Value = serde_json::from_str(&line)
        .map_err(|_| CliError::new("relay_auth", "Invalid relay authentication response"))?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(CliError::new("relay_auth", "Relay authentication failed"));
    }
    Ok(())
}
fn decode_hex(raw: &str) -> Option<Vec<u8>> {
    let bytes = raw.trim().as_bytes();
    if bytes.is_empty() || bytes.len() % 2 != 0 || !bytes.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    bytes
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect()
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|v| format!("{v:02x}")).collect()
}
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut key = if key.len() > 64 {
        Sha256::digest(key).to_vec()
    } else {
        key.to_vec()
    };
    key.resize(64, 0);
    let mut inner = [0x36; 64];
    let mut outer = [0x5c; 64];
    for i in 0..64 {
        inner[i] ^= key[i];
        outer[i] ^= key[i];
    }
    let mut inner_hash = Sha256::new();
    inner_hash.update(inner);
    inner_hash.update(message);
    let mut outer_hash = Sha256::new();
    outer_hash.update(outer);
    outer_hash.update(inner_hash.finalize());
    outer_hash.finalize().into()
}
fn request(method: &str, mut params: Value, environment: &Environment) -> Result<Value> {
    let object = params
        .as_object_mut()
        .ok_or_else(|| CliError::usage("RPC params must be a JSON object"))?;
    if method.starts_with("vm.") {
        for (key, name) in [
            ("cloud_operation_id", "CMUX_CLOUD_OPERATION_ID"),
            ("cloud_trace_id", "CMUX_CLOUD_TRACE_ID"),
            ("cloud_parent_span_id", "CMUX_CLOUD_PARENT_SPAN_ID"),
        ] {
            if let Some(value) = environment.get(name) {
                object.insert(key.into(), Value::String(value.clone()));
            }
        }
    }
    let mut request = json!({"id": uuid::Uuid::new_v4().to_string().to_uppercase(), "method": method, "params": params});
    if let Some(rule) = environment
        .get("CMUX_AUTOMATION_RULE_ID")
        .filter(|s| !s.is_empty())
    {
        request["automation_origin"] = automation_origin(rule, environment);
    }
    Ok(request)
}
fn automation_origin(rule: &str, environment: &Environment) -> Value {
    let raw = environment
        .get("CMUX_AUTOMATION_CHAIN")
        .map(String::as_str)
        .unwrap_or(rule);
    let mut chain = serde_json::from_str::<Vec<String>>(raw)
        .unwrap_or_else(|_| raw.split(',').map(str::to_string).collect());
    chain.retain(|value| !value.is_empty());
    if chain.is_empty() {
        chain.push(rule.to_string());
    }
    json!({"rule_id": rule, "chain": chain})
}
fn automation_origin_command(command: &str, environment: &Environment) -> String {
    if command.starts_with("__cmux_automation_origin ") {
        return command.to_string();
    }
    let Some(rule) = environment
        .get("CMUX_AUTOMATION_RULE_ID")
        .filter(|s| !s.is_empty())
    else {
        return command.to_string();
    };
    let encoded = base64::engine::general_purpose::STANDARD
        .encode(automation_origin(rule, environment).to_string());
    format!("__cmux_automation_origin {encoded} {command}")
}
fn is_complete_single_line(data: &[u8]) -> bool {
    if !data.contains(&b'\n') {
        return false;
    }
    let Ok(text) = std::str::from_utf8(data) else {
        return false;
    };
    let line = text.trim();
    if line.is_empty() || line.contains('\n') {
        return false;
    }
    line == "OK"
        || line == "PONG"
        || line.starts_with("OK ")
        || line.starts_with("ERROR:")
        || serde_json::from_str::<Value>(line).is_ok()
}
fn decode_response(raw: &str) -> Result<Value> {
    let response: Value =
        serde_json::from_str(raw).map_err(|_| CliError::new("protocol", "Invalid v2 response"))?;
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(response
            .get("result")
            .filter(|r| r.is_object())
            .cloned()
            .unwrap_or_else(|| json!({})));
    }
    if let Some(error) = response.get("error").and_then(Value::as_object) {
        let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
        let mut result = CliError::new(code, format_v2_error(error));
        result.retryable = error
            .get("data")
            .and_then(|d| d.get("retryable"))
            .and_then(Value::as_bool)
            == Some(true);
        return Err(result);
    }
    Err(CliError::new("protocol", "v2 request failed"))
}
fn format_v2_error(error: &Map<String, Value>) -> String {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Unknown v2 error");
    let mut result = if code == "vm_error" {
        message.to_string()
    } else if message.contains('\n') {
        format!("{code}:\n{message}")
    } else {
        format!("{code}: {message}")
    };
    let details = safe_details(error.get("details"));
    for (label, value) in [
        ("Reason", error.get("reason").and_then(Value::as_str)),
        ("What to do", error.get("action").and_then(Value::as_str)),
        ("Details", details.as_deref()),
    ] {
        if let Some(value) = normalized(value) {
            result.push_str(&format!("\n\n{label}:\n  {}", value.replace('\n', "\n  ")));
        }
    }
    result
}
fn safe_details(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(value) = value.as_str() {
        return normalized(Some(value)).map(str::to_string);
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
    let mut keys: Vec<_> = object
        .keys()
        .filter(|k| allowed.contains(&k.as_str()))
        .collect();
    keys.sort();
    let rows = keys
        .into_iter()
        .filter_map(|key| {
            let value = &object[key];
            if value.is_null() {
                return None;
            }
            let text = match value {
                Value::String(value) => value.replace('\n', "\\n").replace('\r', "\\r"),
                Value::Array(_) | Value::Object(_) => "available".into(),
                _ => value.to_string(),
            };
            Some(format!("{key}: {text}"))
        })
        .collect::<Vec<_>>()
        .join("\n");
    if rows.is_empty() { None } else { Some(rows) }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{c_char, c_void};
    use std::path::Path;
    type Ref = *const c_void;
    type Index = isize;
    const UTF8: u32 = 0x08000100;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: Ref,
            bytes: *const u8,
            count: Index,
            encoding: u32,
            external: u8,
        ) -> Ref;
        fn CFStringGetCString(value: Ref, buffer: *mut c_char, size: Index, encoding: u32) -> u8;
        fn CFStringGetLength(value: Ref) -> Index;
        fn CFStringGetMaximumSizeForEncoding(length: Index, encoding: u32) -> Index;
        fn CFDictionaryCreate(
            allocator: Ref,
            keys: *const Ref,
            values: *const Ref,
            count: Index,
            key_callbacks: Ref,
            value_callbacks: Ref,
        ) -> Ref;
        fn CFRelease(value: Ref);
        fn CFDataGetLength(value: Ref) -> Index;
        fn CFDataGetBytePtr(value: Ref) -> *const u8;
        fn CFGetTypeID(value: Ref) -> usize;
        fn CFDataGetTypeID() -> usize;
        fn CFURLCreateFromFileSystemRepresentation(
            allocator: Ref,
            bytes: *const u8,
            count: Index,
            directory: u8,
        ) -> Ref;
        fn CFBundleCreate(allocator: Ref, url: Ref) -> Ref;
        fn CFBundleGetIdentifier(bundle: Ref) -> Ref;
        static kCFBooleanTrue: Ref;
    }
    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        fn SecItemCopyMatching(query: Ref, result: *mut Ref) -> i32;
        static kSecClass: Ref;
        static kSecClassGenericPassword: Ref;
        static kSecAttrService: Ref;
        static kSecAttrAccount: Ref;
        static kSecReturnData: Ref;
        static kSecMatchLimit: Ref;
        static kSecMatchLimitOne: Ref;
        static kSecUseAuthenticationUI: Ref;
        static kSecUseAuthenticationUIFail: Ref;
    }
    struct Owned(Ref);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    CFRelease(self.0);
                }
            }
        }
    }
    fn string(value: &str) -> Option<Owned> {
        let value = unsafe {
            CFStringCreateWithBytes(
                std::ptr::null(),
                value.as_ptr(),
                value.len() as Index,
                UTF8,
                0,
            )
        };
        if value.is_null() {
            None
        } else {
            Some(Owned(value))
        }
    }
    pub(super) fn password(service: &str) -> Option<String> {
        let service = string(service)?;
        let account = string("local-socket-password")?;
        unsafe {
            let keys = [
                kSecClass,
                kSecAttrService,
                kSecAttrAccount,
                kSecReturnData,
                kSecMatchLimit,
                kSecUseAuthenticationUI,
            ];
            let values = [
                kSecClassGenericPassword,
                service.0,
                account.0,
                kCFBooleanTrue,
                kSecMatchLimitOne,
                kSecUseAuthenticationUIFail,
            ];
            let query = Owned(CFDictionaryCreate(
                std::ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                keys.len() as Index,
                std::ptr::null(),
                std::ptr::null(),
            ));
            if query.0.is_null() {
                return None;
            }
            let mut result = std::ptr::null();
            let status = SecItemCopyMatching(query.0, &mut result);
            let result = Owned(result);
            if status != 0 || result.0.is_null() || CFGetTypeID(result.0) != CFDataGetTypeID() {
                return None;
            }
            let length = CFDataGetLength(result.0);
            let bytes = CFDataGetBytePtr(result.0);
            if length <= 0 || bytes.is_null() {
                return None;
            }
            String::from_utf8(std::slice::from_raw_parts(bytes, length as usize).to_vec()).ok()
        }
    }
    pub(super) fn bundle_identifier(path: &Path) -> Option<String> {
        use std::os::unix::ffi::OsStrExt;
        let path = path.as_os_str().as_bytes();
        unsafe {
            let url = Owned(CFURLCreateFromFileSystemRepresentation(
                std::ptr::null(),
                path.as_ptr(),
                path.len() as Index,
                1,
            ));
            if url.0.is_null() {
                return None;
            }
            let bundle = Owned(CFBundleCreate(std::ptr::null(), url.0));
            if bundle.0.is_null() {
                return None;
            }
            let identifier = CFBundleGetIdentifier(bundle.0);
            if identifier.is_null() {
                return None;
            }
            let capacity =
                CFStringGetMaximumSizeForEncoding(CFStringGetLength(identifier), UTF8) + 1;
            if capacity <= 0 {
                return None;
            }
            let mut bytes = vec![0u8; capacity as usize];
            if CFStringGetCString(identifier, bytes.as_mut_ptr().cast(), capacity, UTF8) == 0 {
                return None;
            }
            let length = bytes.iter().position(|b| *b == 0)?;
            String::from_utf8(bytes[..length].to_vec())
                .ok()
                .filter(|s| !s.trim().is_empty())
        }
    }
}
