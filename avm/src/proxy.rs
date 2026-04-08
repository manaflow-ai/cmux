use std::collections::VecDeque;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::Result;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

use crate::detector::{Detection, PiiDetector};
use crate::policy::{NetworkPolicy, PolicyAction};

/// Maximum request body size to scan for PII (1 MB).
const MAX_SCAN_BODY_SIZE: usize = 1024 * 1024;

// ---------------------------------------------------------------------------
// Egress log
// ---------------------------------------------------------------------------

/// A logged egress request.
#[derive(Debug, Clone, Serialize)]
pub struct RequestLogEntry {
    pub timestamp_epoch_secs: u64,
    pub method: String,
    pub url: String,
    pub domain: String,
    pub verdict: String,
    pub pii_detections: Vec<Detection>,
}

/// Ring buffer of recent egress log entries.
pub struct EgressLog {
    entries: VecDeque<RequestLogEntry>,
    max_entries: usize,
}

impl EgressLog {
    pub fn new(max_entries: usize) -> Self {
        Self {
            entries: VecDeque::with_capacity(max_entries.min(1024)),
            max_entries,
        }
    }

    pub fn push(&mut self, entry: RequestLogEntry) {
        if self.entries.len() >= self.max_entries {
            self.entries.pop_front();
        }
        self.entries.push_back(entry);
    }

    /// Get the most recent `count` entries (newest first).
    pub fn recent(&self, count: usize) -> Vec<&RequestLogEntry> {
        self.entries.iter().rev().take(count).collect()
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

impl Default for EgressLog {
    fn default() -> Self {
        Self::new(1000)
    }
}

// ---------------------------------------------------------------------------
// Shared proxy state
// ---------------------------------------------------------------------------

/// State shared between the proxy and the daemon server.
pub struct ProxyState {
    pub network_policy: NetworkPolicy,
    pub detector: PiiDetector,
    pub log: EgressLog,
}

// ---------------------------------------------------------------------------
// Domain / URL helpers
// ---------------------------------------------------------------------------

/// Check a domain against the network policy allow/deny lists.
pub fn check_domain(domain: &str, policy: &NetworkPolicy) -> PolicyAction {
    let domain_lower = domain.to_lowercase();

    // Allow list (exact or subdomain match).
    for allowed in &policy.allow_domains {
        let allowed_lower = allowed.to_lowercase();
        if domain_lower == allowed_lower
            || domain_lower.ends_with(&format!(".{allowed_lower}"))
        {
            return PolicyAction::Warn; // Allowed — just log.
        }
    }

    // Block list.
    for blocked in &policy.block_domains {
        let blocked_lower = blocked.to_lowercase();
        if domain_lower == blocked_lower
            || domain_lower.ends_with(&format!(".{blocked_lower}"))
        {
            return PolicyAction::Block;
        }
    }

    policy.default_action
}

/// Extract the domain (host) from a URL or `host:port` string.
pub fn extract_domain(url: &str) -> Option<String> {
    if !url.contains("://") {
        // CONNECT style: host:port
        return url.split(':').next().map(str::to_string);
    }
    // URL style: http://host:port/path
    let after_scheme = url.split("://").nth(1)?;
    let host_port = after_scheme.split('/').next()?;
    Some(host_port.split(':').next()?.to_string())
}

/// Extract the port from a URL or `host:port` string.
pub fn extract_port(url: &str) -> Option<u16> {
    if !url.contains("://") {
        return url.split(':').nth(1)?.parse().ok();
    }
    let after_scheme = url.split("://").nth(1)?;
    let host_port = after_scheme.split('/').next()?;
    host_port.split(':').nth(1)?.parse().ok()
}

/// Extract the path component from a full URL. Returns "/" if none.
pub fn extract_path(url: &str) -> &str {
    if let Some(after_scheme) = url.split("://").nth(1) {
        if let Some(slash_pos) = after_scheme.find('/') {
            return &after_scheme[slash_pos..];
        }
    }
    "/"
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn verdict_str(action: PolicyAction) -> String {
    match action {
        PolicyAction::Warn => "allowed".into(),
        PolicyAction::Ask => "ask".into(),
        PolicyAction::Block => "blocked".into(),
    }
}

fn worse_action(a: PolicyAction, b: PolicyAction) -> PolicyAction {
    let rank = |action: PolicyAction| -> u8 {
        match action {
            PolicyAction::Warn => 0,
            PolicyAction::Ask => 1,
            PolicyAction::Block => 2,
        }
    };
    if rank(a) >= rank(b) { a } else { b }
}

fn parse_content_length(header_line: &str) -> Option<usize> {
    let line = header_line.trim();
    let lower = line.to_lowercase();
    lower
        .strip_prefix("content-length:")
        .and_then(|rest| rest.trim().parse().ok())
}

// ---------------------------------------------------------------------------
// Proxy server
// ---------------------------------------------------------------------------

/// Start the egress proxy on a random available port.
/// Returns the bound port number.
pub async fn start_proxy(state: Arc<Mutex<ProxyState>>) -> Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();

    tracing::info!(port, "egress proxy listening");

    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    let state = Arc::clone(&state);
                    tokio::spawn(async move {
                        if let Err(e) = handle_proxy_connection(stream, state).await {
                            tracing::debug!("proxy connection error: {e}");
                        }
                    });
                }
                Err(e) => {
                    tracing::error!("proxy accept error: {e}");
                }
            }
        }
    });

    Ok(port)
}

/// Handle a single proxy connection.
///
/// Reads the HTTP request line + headers, dispatches to CONNECT or HTTP
/// forwarding handler based on the method.
async fn handle_proxy_connection(
    mut stream: TcpStream,
    state: Arc<Mutex<ProxyState>>,
) -> Result<()> {
    // Read until we find \r\n\r\n (end of HTTP headers).
    let mut buf = Vec::with_capacity(8192);
    let mut temp = [0u8; 4096];

    loop {
        let n = stream.read(&mut temp).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&temp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 65536 {
            stream
                .write_all(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
                .await?;
            return Ok(());
        }
    }

    // Split headers from any trailing body bytes.
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .unwrap_or(buf.len());
    let body_start = header_end + 4;
    let remaining_body = if body_start < buf.len() {
        &buf[body_start..]
    } else {
        &[]
    };

    // Parse request line and headers.
    let headers_str = String::from_utf8_lossy(&buf[..header_end]);
    let mut lines = headers_str.lines();
    let request_line = lines.next().unwrap_or_default().to_string();

    let mut header_lines: Vec<String> = Vec::new();
    let mut content_length: usize = 0;
    for line in lines {
        if let Some(cl) = parse_content_length(line) {
            content_length = cl;
        }
        header_lines.push(line.to_string());
    }

    let parts: Vec<&str> = request_line.split_whitespace().collect();
    if parts.len() < 2 {
        write_error(&mut stream, "400 Bad Request", "Invalid request line").await?;
        return Ok(());
    }

    let method = parts[0];
    let target = parts[1];

    if method.eq_ignore_ascii_case("CONNECT") {
        handle_connect(target, remaining_body, &mut stream, &state).await
    } else {
        handle_http_forward(
            method,
            target,
            &header_lines,
            content_length,
            remaining_body,
            &mut stream,
            &state,
        )
        .await
    }
}

/// Handle HTTP CONNECT (HTTPS tunneling).
async fn handle_connect(
    target: &str,
    remaining_data: &[u8],
    stream: &mut TcpStream,
    state: &Arc<Mutex<ProxyState>>,
) -> Result<()> {
    let domain = extract_domain(target).unwrap_or_default();
    let port = extract_port(target).unwrap_or(443);

    let verdict = {
        let s = state.lock().await;
        check_domain(&domain, &s.network_policy)
    };

    // Log the request.
    {
        let mut s = state.lock().await;
        s.log.push(RequestLogEntry {
            timestamp_epoch_secs: now_epoch_secs(),
            method: "CONNECT".into(),
            url: target.into(),
            domain: domain.clone(),
            verdict: verdict_str(verdict),
            pii_detections: vec![],
        });
    }

    if verdict == PolicyAction::Block {
        write_error(stream, "403 Forbidden", "Blocked by AVM egress policy").await?;
        return Ok(());
    }
    if verdict == PolicyAction::Ask {
        write_error(
            stream,
            "403 Forbidden",
            "Requires approval (not yet integrated)",
        )
        .await?;
        return Ok(());
    }

    // Connect to upstream.
    let upstream_result = TcpStream::connect(format!("{domain}:{port}")).await;
    let mut upstream = match upstream_result {
        Ok(s) => s,
        Err(e) => {
            write_error(
                stream,
                "502 Bad Gateway",
                &format!("Upstream connection failed: {e}"),
            )
            .await?;
            return Ok(());
        }
    };

    // Tell client the tunnel is established.
    stream
        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        .await?;

    // Forward any bytes we already read past the request headers.
    if !remaining_data.is_empty() {
        upstream.write_all(remaining_data).await?;
    }

    // Bidirectional tunnel until either side closes.
    let _ = tokio::io::copy_bidirectional(stream, &mut upstream).await;

    Ok(())
}

/// Handle plain HTTP request forwarding.
#[allow(clippy::too_many_arguments)]
async fn handle_http_forward(
    method: &str,
    target: &str,
    headers: &[String],
    content_length: usize,
    remaining_body: &[u8],
    stream: &mut TcpStream,
    state: &Arc<Mutex<ProxyState>>,
) -> Result<()> {
    let domain = extract_domain(target).unwrap_or_default();
    let port = extract_port(target).unwrap_or(80);
    let path = extract_path(target);

    // Check domain.
    let domain_verdict = {
        let s = state.lock().await;
        check_domain(&domain, &s.network_policy)
    };

    // Read the full body if any.
    let body_remaining = content_length.saturating_sub(remaining_body.len());
    let mut body = remaining_body.to_vec();
    if body_remaining > 0 {
        let mut rest = vec![0u8; body_remaining];
        stream.read_exact(&mut rest).await?;
        body.extend_from_slice(&rest);
    }

    // Scan body for PII (only up to MAX_SCAN_BODY_SIZE).
    let pii_detections = if !body.is_empty() && body.len() <= MAX_SCAN_BODY_SIZE {
        let body_str = String::from_utf8_lossy(&body);
        let s = state.lock().await;
        s.detector.scan(&body_str)
    } else {
        vec![]
    };

    let pii_worst = PiiDetector::worst_action(&pii_detections);
    let final_verdict =
        worse_action(domain_verdict, pii_worst.unwrap_or(PolicyAction::Warn));

    // Log.
    {
        let mut s = state.lock().await;
        s.log.push(RequestLogEntry {
            timestamp_epoch_secs: now_epoch_secs(),
            method: method.into(),
            url: target.into(),
            domain: domain.clone(),
            verdict: verdict_str(final_verdict),
            pii_detections,
        });
    }

    if final_verdict == PolicyAction::Block {
        let msg = "Blocked by AVM egress policy";
        write_error(stream, "403 Forbidden", msg).await?;
        return Ok(());
    }
    if final_verdict == PolicyAction::Ask {
        write_error(stream, "403 Forbidden", "Requires approval").await?;
        return Ok(());
    }

    // Connect to upstream.
    let upstream_result = TcpStream::connect(format!("{domain}:{port}")).await;
    let mut upstream = match upstream_result {
        Ok(s) => s,
        Err(e) => {
            write_error(
                stream,
                "502 Bad Gateway",
                &format!("Upstream connection failed: {e}"),
            )
            .await?;
            return Ok(());
        }
    };

    // Build forwarded request with relative path.
    let mut request = format!("{method} {path} HTTP/1.1\r\n");
    for header in headers {
        let lower = header.to_lowercase();
        if !lower.starts_with("proxy-") {
            request.push_str(header);
            request.push_str("\r\n");
        }
    }
    request.push_str("Connection: close\r\n");
    request.push_str("\r\n");

    upstream.write_all(request.as_bytes()).await?;
    if !body.is_empty() {
        upstream.write_all(&body).await?;
    }

    // Relay response from upstream to client.
    let _ = tokio::io::copy(&mut upstream, stream).await;

    Ok(())
}

/// Write an HTTP error response to the client.
async fn write_error(stream: &mut TcpStream, status: &str, body: &str) -> Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::NetworkPolicy;

    #[test]
    fn check_domain_allow_list() {
        let policy = NetworkPolicy {
            allow_domains: vec!["github.com".into(), "api.openai.com".into()],
            block_domains: vec![],
            default_action: PolicyAction::Block,
        };
        // Exact match
        assert_eq!(check_domain("github.com", &policy), PolicyAction::Warn);
        // Subdomain match
        assert_eq!(
            check_domain("api.github.com", &policy),
            PolicyAction::Warn
        );
        // Not in list — falls through to default (Block)
        assert_eq!(
            check_domain("evil.com", &policy),
            PolicyAction::Block
        );
    }

    #[test]
    fn check_domain_block_list() {
        let policy = NetworkPolicy {
            allow_domains: vec![],
            block_domains: vec!["evil.com".into()],
            default_action: PolicyAction::Warn,
        };
        assert_eq!(
            check_domain("evil.com", &policy),
            PolicyAction::Block
        );
        assert_eq!(
            check_domain("sub.evil.com", &policy),
            PolicyAction::Block
        );
        assert_eq!(
            check_domain("good.com", &policy),
            PolicyAction::Warn
        );
    }

    #[test]
    fn check_domain_case_insensitive() {
        let policy = NetworkPolicy {
            allow_domains: vec!["GitHub.com".into()],
            block_domains: vec![],
            default_action: PolicyAction::Block,
        };
        assert_eq!(
            check_domain("github.COM", &policy),
            PolicyAction::Warn
        );
    }

    #[test]
    fn extract_domain_connect_style() {
        assert_eq!(
            extract_domain("example.com:443"),
            Some("example.com".into())
        );
    }

    #[test]
    fn extract_domain_url_style() {
        assert_eq!(
            extract_domain("http://example.com:8080/path"),
            Some("example.com".into())
        );
        assert_eq!(
            extract_domain("https://api.github.com/repos"),
            Some("api.github.com".into())
        );
    }

    #[test]
    fn extract_port_connect() {
        assert_eq!(extract_port("example.com:8443"), Some(8443));
    }

    #[test]
    fn extract_port_url() {
        assert_eq!(
            extract_port("http://example.com:8080/path"),
            Some(8080)
        );
        assert_eq!(extract_port("http://example.com/path"), None);
    }

    #[test]
    fn extract_path_works() {
        assert_eq!(
            extract_path("http://example.com/api/v1/data"),
            "/api/v1/data"
        );
        assert_eq!(extract_path("http://example.com"), "/");
        assert_eq!(
            extract_path("http://example.com:8080/path?q=1"),
            "/path?q=1"
        );
    }

    #[test]
    fn parse_content_length_works() {
        assert_eq!(parse_content_length("Content-Length: 42"), Some(42));
        assert_eq!(parse_content_length("content-length: 100"), Some(100));
        assert_eq!(parse_content_length("Host: example.com"), None);
    }

    #[test]
    fn egress_log_ring_buffer() {
        let mut log = EgressLog::new(3);
        for i in 0..5 {
            log.push(RequestLogEntry {
                timestamp_epoch_secs: i,
                method: "GET".into(),
                url: format!("http://example.com/{i}"),
                domain: "example.com".into(),
                verdict: "allowed".into(),
                pii_detections: vec![],
            });
        }
        assert_eq!(log.len(), 3);
        let recent = log.recent(10);
        // Most recent should be entry 4, 3, 2
        assert_eq!(recent[0].timestamp_epoch_secs, 4);
        assert_eq!(recent[2].timestamp_epoch_secs, 2);
    }

    #[test]
    fn worse_action_picks_most_restrictive() {
        assert_eq!(
            worse_action(PolicyAction::Warn, PolicyAction::Block),
            PolicyAction::Block
        );
        assert_eq!(
            worse_action(PolicyAction::Block, PolicyAction::Warn),
            PolicyAction::Block
        );
        assert_eq!(
            worse_action(PolicyAction::Ask, PolicyAction::Warn),
            PolicyAction::Ask
        );
    }
}
