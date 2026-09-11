use std::{
    ffi::{CStr, CString},
    io,
    os::raw::c_char,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use iroh::{
    Endpoint,
    endpoint::{Connection, RecvStream, SendStream, presets},
    protocol::{AcceptError, ProtocolHandler, Router},
};
use iroh_tickets::{Ticket, endpoint::EndpointTicket};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub const ALPN: &[u8] = b"cmux/iroh-phone-mac-demo/0";
const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(6);
static CLIENT_CACHE: OnceLock<Mutex<Option<CachedClient>>> = OnceLock::new();

#[derive(Debug, Clone)]
pub enum MacEvent {
    Connected {
        remote_id: String,
    },
    PingRequest {
        remote_id: String,
        message: String,
    },
    PingResponse {
        remote_id: String,
        bytes: usize,
        handling_ms: u64,
    },
    TerminalRequest {
        remote_id: String,
        command: String,
    },
    TerminalResponse {
        remote_id: String,
        bytes: usize,
        exit_code: Option<i32>,
        handling_ms: u64,
    },
    Error {
        message: String,
    },
}

pub struct MacServer {
    pub ticket: String,
    pub events: mpsc::UnboundedReceiver<MacEvent>,
    router: Router,
}

impl MacServer {
    pub async fn shutdown(self) -> Result<()> {
        self.router.shutdown().await?;
        Ok(())
    }
}

#[derive(Debug, Clone)]
struct DemoProtocol {
    events: mpsc::UnboundedSender<MacEvent>,
}

impl ProtocolHandler for DemoProtocol {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let events = self.events.clone();
        handle_connection(connection, events).await
    }
}

pub async fn start_mac_server() -> Result<MacServer> {
    let (events_tx, events_rx) = mpsc::unbounded_channel();
    let endpoint = Endpoint::bind(presets::N0).await?;
    endpoint.online().await;

    let ticket = EndpointTicket::new(endpoint.addr()).to_string();
    let router = Router::builder(endpoint)
        .accept(ALPN, DemoProtocol { events: events_tx })
        .spawn();

    Ok(MacServer {
        ticket,
        events: events_rx,
        router,
    })
}

async fn handle_connection(
    connection: Connection,
    events: mpsc::UnboundedSender<MacEvent>,
) -> Result<(), AcceptError> {
    let remote_id = connection.remote_id().to_string();
    send_event(
        &events,
        MacEvent::Connected {
            remote_id: remote_id.clone(),
        },
    );

    loop {
        let (mut send, mut recv): (SendStream, RecvStream) = match connection.accept_bi().await {
            Ok(streams) => streams,
            Err(_) => break,
        };
        let request_bytes = recv
            .read_to_end(MAX_MESSAGE_BYTES)
            .await
            .map_err(AcceptError::from_err)?;
        let response = handle_request(&remote_id, &request_bytes, &events)
            .await
            .map_err(accept_error)?;
        let payload = serde_json::to_vec(&response).map_err(AcceptError::from_err)?;
        send.write_all(&payload)
            .await
            .map_err(AcceptError::from_err)?;
        send.finish().map_err(AcceptError::from_err)?;
    }

    connection.closed().await;
    Ok(())
}

async fn handle_request(
    remote_id: &str,
    request_bytes: &[u8],
    events: &mpsc::UnboundedSender<MacEvent>,
) -> Result<WireResponse> {
    match decode_request(request_bytes)? {
        WireRequest::Ping { message } => {
            let start = Instant::now();
            send_event(
                events,
                MacEvent::PingRequest {
                    remote_id: remote_id.to_string(),
                    message: message.clone(),
                },
            );
            let response = WireResponse::Ping {
                reply: format!("MacBook received: {message}"),
                mac_received: message,
                remote_id: remote_id.to_string(),
                received_at_unix_ms: unix_ms(),
            };
            let bytes = serde_json::to_vec(&response)?.len();
            send_event(
                events,
                MacEvent::PingResponse {
                    remote_id: remote_id.to_string(),
                    bytes,
                    handling_ms: elapsed_ms(start),
                },
            );
            Ok(response)
        }
        WireRequest::Terminal { command } => {
            let start = Instant::now();
            send_event(
                events,
                MacEvent::TerminalRequest {
                    remote_id: remote_id.to_string(),
                    command: command.clone(),
                },
            );
            let result = run_pty_command(command).await?;
            let response = WireResponse::Terminal {
                output: result.output,
                exit_code: result.exit_code,
                remote_id: remote_id.to_string(),
                received_at_unix_ms: unix_ms(),
            };
            let bytes = serde_json::to_vec(&response)?.len();
            send_event(
                events,
                MacEvent::TerminalResponse {
                    remote_id: remote_id.to_string(),
                    bytes,
                    exit_code: result.exit_code,
                    handling_ms: elapsed_ms(start),
                },
            );
            Ok(response)
        }
    }
}

fn decode_request(request_bytes: &[u8]) -> Result<WireRequest> {
    if let Ok(request) = serde_json::from_slice(request_bytes) {
        return Ok(request);
    }

    Ok(WireRequest::Ping {
        message: String::from_utf8_lossy(request_bytes).to_string(),
    })
}

fn send_event(events: &mpsc::UnboundedSender<MacEvent>, event: MacEvent) {
    let _ = events.send(event);
}

fn accept_error(error: anyhow::Error) -> AcceptError {
    AcceptError::from_err(io::Error::other(error.to_string()))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WireRequest {
    Ping { message: String },
    Terminal { command: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WireResponse {
    Ping {
        reply: String,
        mac_received: String,
        remote_id: String,
        received_at_unix_ms: u64,
    },
    Terminal {
        output: String,
        exit_code: Option<i32>,
        remote_id: String,
        received_at_unix_ms: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PingWireResponse {
    pub reply: String,
    pub mac_received: String,
    pub remote_id: String,
    pub received_at_unix_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalWireResponse {
    pub output: String,
    pub exit_code: Option<i32>,
    pub remote_id: String,
    pub received_at_unix_ms: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct PingSummary {
    pub rtt_ms: u64,
    pub response: PingWireResponse,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalSummary {
    pub rtt_ms: u64,
    pub response: TerminalWireResponse,
}

pub async fn ping_ticket(ticket: &str, message: &str) -> Result<PingSummary> {
    let summary = send_wire_request(
        ticket,
        &WireRequest::Ping {
            message: message.to_string(),
        },
    )
    .await?;

    match summary.response {
        WireResponse::Ping {
            reply,
            mac_received,
            remote_id,
            received_at_unix_ms,
        } => Ok(PingSummary {
            rtt_ms: summary.rtt_ms,
            response: PingWireResponse {
                reply,
                mac_received,
                remote_id,
                received_at_unix_ms,
            },
        }),
        WireResponse::Terminal { .. } => anyhow::bail!("mac returned terminal response to ping"),
    }
}

pub async fn terminal_command(ticket: &str, command: &str) -> Result<TerminalSummary> {
    let summary = send_wire_request(
        ticket,
        &WireRequest::Terminal {
            command: command.to_string(),
        },
    )
    .await?;

    match summary.response {
        WireResponse::Terminal {
            output,
            exit_code,
            remote_id,
            received_at_unix_ms,
        } => Ok(TerminalSummary {
            rtt_ms: summary.rtt_ms,
            response: TerminalWireResponse {
                output,
                exit_code,
                remote_id,
                received_at_unix_ms,
            },
        }),
        WireResponse::Ping { .. } => {
            anyhow::bail!("mac returned ping response to terminal command")
        }
    }
}

struct WireSummary {
    rtt_ms: u64,
    response: WireResponse,
}

async fn send_wire_request(ticket: &str, request: &WireRequest) -> Result<WireSummary> {
    let ticket = <EndpointTicket as Ticket>::deserialize(ticket.trim())
        .map_err(|error| anyhow::anyhow!("failed to parse iroh ticket: {error}"))?;
    let endpoint = Endpoint::bind(presets::N0).await?;
    let start = Instant::now();
    let connection = match tokio::time::timeout(
        CONNECT_TIMEOUT,
        endpoint.connect(ticket.endpoint_addr().clone(), ALPN),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => {
            endpoint.close().await;
            anyhow::bail!(
                "iroh connect timed out after {} ms",
                CONNECT_TIMEOUT.as_millis()
            );
        }
    };
    let summary = send_wire_request_on_connection(&connection, request, start).await?;

    connection.close(0u32.into(), b"done");
    endpoint.close().await;

    Ok(summary)
}

async fn send_wire_request_on_connection(
    connection: &Connection,
    request: &WireRequest,
    start: Instant,
) -> Result<WireSummary> {
    let response = tokio::time::timeout(REQUEST_TIMEOUT, async {
        let (mut send, mut recv): (SendStream, RecvStream) = connection.open_bi().await?;

        let request = serde_json::to_vec(request)?;
        send.write_all(&request).await?;
        send.finish()?;

        let response_bytes = recv.read_to_end(MAX_MESSAGE_BYTES).await?;
        let response: WireResponse = serde_json::from_slice(&response_bytes)
            .context("mac returned invalid demo response")?;
        Ok::<_, anyhow::Error>(response)
    })
    .await
    .map_err(|_| {
        anyhow::anyhow!(
            "iroh request timed out after {} ms",
            REQUEST_TIMEOUT.as_millis()
        )
    })??;

    Ok(WireSummary {
        rtt_ms: elapsed_ms(start),
        response,
    })
}

#[derive(Serialize)]
struct FfiPingOk<'a> {
    ok: bool,
    rtt_ms: u64,
    reply: &'a str,
    mac_received: &'a str,
    remote_id: &'a str,
    received_at_unix_ms: u64,
}

#[derive(Serialize)]
struct FfiPingError<'a> {
    ok: bool,
    error: &'a str,
}

#[derive(Serialize)]
struct FfiTerminalOk<'a> {
    ok: bool,
    rtt_ms: u64,
    output: &'a str,
    exit_code: Option<i32>,
    remote_id: &'a str,
    received_at_unix_ms: u64,
}

struct CachedClient {
    ticket: String,
    runtime: tokio::runtime::Runtime,
    endpoint: Endpoint,
    connection: Connection,
}

impl CachedClient {
    fn connect(ticket: String) -> Result<Self> {
        let parsed_ticket = <EndpointTicket as Ticket>::deserialize(ticket.trim())
            .map_err(|error| anyhow::anyhow!("failed to parse iroh ticket: {error}"))?;
        let runtime = tokio::runtime::Runtime::new()?;
        let (endpoint, connection) = runtime.block_on(async {
            let endpoint = Endpoint::bind(presets::N0).await?;
            let connection = match tokio::time::timeout(
                CONNECT_TIMEOUT,
                endpoint.connect(parsed_ticket.endpoint_addr().clone(), ALPN),
            )
            .await
            {
                Ok(result) => result?,
                Err(_) => {
                    endpoint.close().await;
                    anyhow::bail!(
                        "iroh connect timed out after {} ms",
                        CONNECT_TIMEOUT.as_millis()
                    );
                }
            };
            Ok::<_, anyhow::Error>((endpoint, connection))
        })?;

        Ok(Self {
            ticket,
            runtime,
            endpoint,
            connection,
        })
    }

    fn send(&self, request: &WireRequest, start: Instant) -> Result<WireSummary> {
        self.runtime.block_on(send_wire_request_on_connection(
            &self.connection,
            request,
            start,
        ))
    }
}

impl Drop for CachedClient {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"done");
        self.runtime.block_on(self.endpoint.close());
    }
}

fn send_cached_wire_request(ticket: &str, request: &WireRequest) -> Result<WireSummary> {
    let ticket = ticket.trim().to_string();
    let cache = CLIENT_CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cache
        .lock()
        .map_err(|_| anyhow::anyhow!("iroh client cache is poisoned"))?;

    let needs_connection = guard
        .as_ref()
        .map(|client| client.ticket != ticket)
        .unwrap_or(true);
    if needs_connection {
        *guard = Some(CachedClient::connect(ticket.clone())?);
    }

    let first_result = guard
        .as_ref()
        .context("iroh client cache missing after connect")?
        .send(request, Instant::now());
    if first_result.is_ok() {
        return first_result;
    }

    *guard = None;
    *guard = Some(CachedClient::connect(ticket)?);
    guard
        .as_ref()
        .context("iroh client cache missing after reconnect")?
        .send(request, Instant::now())
}

#[unsafe(no_mangle)]
pub extern "C" fn iroh_demo_ping(ticket: *const c_char, message: *const c_char) -> *mut c_char {
    let result = ffi_ping(ticket, message);
    let json = match result {
        Ok(summary) => serde_json::to_string(&FfiPingOk {
            ok: true,
            rtt_ms: summary.rtt_ms,
            reply: &summary.response.reply,
            mac_received: &summary.response.mac_received,
            remote_id: &summary.response.remote_id,
            received_at_unix_ms: summary.response.received_at_unix_ms,
        }),
        Err(error) => serde_json::to_string(&FfiPingError {
            ok: false,
            error: &error.to_string(),
        }),
    }
    .unwrap_or_else(|error| {
        format!(r#"{{"ok":false,"error":"failed to encode FFI response: {error}"}}"#)
    });

    CString::new(json).unwrap_or_else(empty_c_string).into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn iroh_demo_terminal_command(
    ticket: *const c_char,
    command: *const c_char,
) -> *mut c_char {
    let result = ffi_terminal_command(ticket, command);
    let json = match result {
        Ok(summary) => serde_json::to_string(&FfiTerminalOk {
            ok: true,
            rtt_ms: summary.rtt_ms,
            output: &summary.response.output,
            exit_code: summary.response.exit_code,
            remote_id: &summary.response.remote_id,
            received_at_unix_ms: summary.response.received_at_unix_ms,
        }),
        Err(error) => serde_json::to_string(&FfiPingError {
            ok: false,
            error: &error.to_string(),
        }),
    }
    .unwrap_or_else(|error| {
        format!(r#"{{"ok":false,"error":"failed to encode FFI response: {error}"}}"#)
    });

    CString::new(json).unwrap_or_else(empty_c_string).into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn iroh_demo_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }

    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

fn ffi_ping(ticket: *const c_char, message: *const c_char) -> Result<PingSummary> {
    let ticket = c_string(ticket).context("missing ticket")?;
    let message = c_string(message).context("missing message")?;
    let summary = send_cached_wire_request(
        &ticket,
        &WireRequest::Ping {
            message: message.to_string(),
        },
    )?;

    match summary.response {
        WireResponse::Ping {
            reply,
            mac_received,
            remote_id,
            received_at_unix_ms,
        } => Ok(PingSummary {
            rtt_ms: summary.rtt_ms,
            response: PingWireResponse {
                reply,
                mac_received,
                remote_id,
                received_at_unix_ms,
            },
        }),
        WireResponse::Terminal { .. } => anyhow::bail!("mac returned terminal response to ping"),
    }
}

fn ffi_terminal_command(ticket: *const c_char, command: *const c_char) -> Result<TerminalSummary> {
    let ticket = c_string(ticket).context("missing ticket")?;
    let command = c_string(command).context("missing command")?;
    let summary = send_cached_wire_request(
        &ticket,
        &WireRequest::Terminal {
            command: command.to_string(),
        },
    )?;

    match summary.response {
        WireResponse::Terminal {
            output,
            exit_code,
            remote_id,
            received_at_unix_ms,
        } => Ok(TerminalSummary {
            rtt_ms: summary.rtt_ms,
            response: TerminalWireResponse {
                output,
                exit_code,
                remote_id,
                received_at_unix_ms,
            },
        }),
        WireResponse::Ping { .. } => {
            anyhow::bail!("mac returned ping response to terminal command")
        }
    }
}

#[derive(Debug, Clone)]
struct PtyCommandResult {
    output: String,
    exit_code: Option<i32>,
}

async fn run_pty_command(command: String) -> Result<PtyCommandResult> {
    tokio::task::spawn_blocking(move || run_pty_command_blocking(&command)).await?
}

#[cfg(target_os = "macos")]
fn run_pty_command_blocking(command: &str) -> Result<PtyCommandResult> {
    use std::io::Read;

    use portable_pty::{CommandBuilder, PtySize};

    let pty_system = portable_pty::native_pty_system();
    let pair = pty_system.openpty(PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    let mut builder = CommandBuilder::new("/bin/zsh");
    builder.arg("-lc");
    builder.arg(command);
    builder.env("TERM", "xterm-256color");

    let mut child = pair.slave.spawn_command(builder)?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader()?;
    let mut output = Vec::new();
    reader.read_to_end(&mut output)?;
    let status = child.wait()?;

    Ok(PtyCommandResult {
        output: String::from_utf8_lossy(&output).to_string(),
        exit_code: Some(status.exit_code().try_into().unwrap_or(i32::MAX)),
    })
}

#[cfg(not(target_os = "macos"))]
fn run_pty_command_blocking(_command: &str) -> Result<PtyCommandResult> {
    anyhow::bail!("Mac PTY is only available on the macOS TUI side")
}

fn c_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }

    let value = unsafe { CStr::from_ptr(ptr) };
    Some(value.to_string_lossy().into_owned())
}

fn empty_c_string(error: std::ffi::NulError) -> CString {
    let without_nuls = error
        .into_vec()
        .into_iter()
        .filter(|byte| *byte != 0)
        .collect::<Vec<_>>();
    CString::new(without_nuls).unwrap_or_default()
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().try_into().unwrap_or(u64::MAX))
        .unwrap_or_default()
}

fn elapsed_ms(start: Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}
