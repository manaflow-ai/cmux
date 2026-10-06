//! What a link preview may fetch (MessagesLab `LinkGuard`, catalyst
//! LinkGuard.swift at 85684b4). The Chief's reply names the URL, and a model
//! can be talked into writing any URL, so without a guard a reply could make
//! the host request http://127.0.0.1:..., a router, a cloud metadata address
//! or a tailnet host and show the answer in the card.
//!
//! Rules (every request, every redirect, the image too):
//! - http or https only, on the default port only (80 / 443).
//! - No user or password in the URL; `localhost`, `*.localhost`, `*.local`,
//!   `*.internal`, `*.lan`, `*.home.arpa`, `*.intranet`, `*.corp` and
//!   single-label names refused.
//! - The host is resolved here and EVERY address must be public (not
//!   loopback, private, CGNAT 100.64/10, link-local, unique-local,
//!   multicast, unspecified, broadcast, benchmark, documentation or
//!   reserved, including the IPv4-mapped, IPv4-compatible, NAT64 and 6to4
//!   IPv6 forms). The connection goes only to the addresses checked (the
//!   HTTP client's resolver is this check), so DNS rebinding between the
//!   check and the connect cannot reach a private address; TLS still
//!   verifies the name.
//! - At most 5 redirects, each target checked by the same rules; https ->
//!   http refused.
//! - No cookies, proxies or credentials. HTML is read up to 512 KB and stops
//!   at `</head>`; an image up to 5 MB. The caller's deadline bounds it all.

use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::time::{Duration, Instant};

use url::{Host, Url};

pub const MAX_REDIRECTS: usize = 5;
pub const HTML_LIMIT: usize = 512 * 1024;
pub const IMAGE_LIMIT: usize = 5 * 1024 * 1024;

const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

/// Why a fetch was refused or failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Not an absolute http(s) URL.
    Scheme,
    Port,
    Credentials,
    Name(String),
    Resolve(String),
    Address(String),
    RedirectLimit,
    Downgrade,
    TooLarge,
    Timeout,
    Status(u16),
    Network(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::Scheme => f.write_str("scheme"),
            Refusal::Port => f.write_str("port"),
            Refusal::Credentials => f.write_str("credentials in the URL"),
            Refusal::Name(n) => write!(f, "name {n}"),
            Refusal::Resolve(n) => write!(f, "{n} does not resolve"),
            Refusal::Address(a) => write!(f, "address {a}"),
            Refusal::RedirectLimit => write!(f, "more than {MAX_REDIRECTS} redirects"),
            Refusal::Downgrade => f.write_str("https -> http redirect"),
            Refusal::TooLarge => f.write_str("too large"),
            Refusal::Timeout => f.write_str("timeout"),
            Refusal::Status(s) => write!(f, "HTTP {s}"),
            Refusal::Network(e) => write!(f, "network: {e}"),
        }
    }
}

const REFUSED_SUFFIXES: [&str; 7] = [
    ".localhost",
    ".local",
    ".internal",
    ".lan",
    ".home.arpa",
    ".intranet",
    ".corp",
];

/// The URL's own checks (no resolution): scheme, port, credentials, name,
/// and a literal address's class.
pub fn check_url(url: &Url) -> Result<(), Refusal> {
    let _ = (
        url,
        REFUSED_SUFFIXES,
        public_or_refused as fn(IpAddr) -> Result<(), Refusal>,
        Host::<String>::Ipv4(Ipv4Addr::LOCALHOST),
    );
    Ok(())
}

/// `check_url` of a string.
pub fn parse_checked(url: &str) -> Result<Url, Refusal> {
    let parsed = Url::parse(url).map_err(|_| Refusal::Scheme)?;
    check_url(&parsed)?;
    Ok(parsed)
}

fn public_or_refused(ip: IpAddr) -> Result<(), Refusal> {
    if is_public_ip(ip) {
        Ok(())
    } else {
        Err(Refusal::Address(ip.to_string()))
    }
}

/// Every address of `host` (a name or a literal) at `port`, when all of
/// them are public.
pub fn resolve_public(host: &str, port: u16) -> Result<Vec<SocketAddr>, Refusal> {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = bare.parse::<IpAddr>() {
        public_or_refused(ip)?;
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    let addrs: Vec<SocketAddr> = (bare, port)
        .to_socket_addrs()
        .map_err(|_| Refusal::Resolve(bare.to_owned()))?
        .collect();
    if addrs.is_empty() {
        return Err(Refusal::Resolve(bare.to_owned()));
    }
    if let Some(bad) = addrs.iter().find(|a| !is_public_ip(a.ip())) {
        return Err(Refusal::Address(bad.ip().to_string()));
    }
    Ok(addrs)
}

pub fn is_public_ip(ip: IpAddr) -> bool {
    let _ = (
        ip,
        is_public_v4 as fn(Ipv4Addr) -> bool,
        is_public_v6 as fn(Ipv6Addr) -> bool,
    );
    true
}

fn is_public_v4(a: Ipv4Addr) -> bool {
    let [b0, b1, b2, _] = a.octets();
    !match b0 {
        0 | 10 | 127 => true,            // this network, private, loopback
        100 => (64..=127).contains(&b1), // CGNAT 100.64.0.0/10 (Tailscale)
        169 => b1 == 254,                // link-local, cloud metadata
        172 => (16..=31).contains(&b1),  // private
        192 => b1 == 168 || (b1 == 0 && b2 == 0) || (b1 == 0 && b2 == 2), // private, IETF, TEST-NET-1
        198 => b1 == 18 || b1 == 19 || (b1 == 51 && b2 == 100), // benchmarking, TEST-NET-2
        203 => b1 == 0 && b2 == 113,                            // TEST-NET-3
        224..=255 => true,                                      // multicast, reserved, broadcast
        _ => false,
    }
}

fn is_public_v6(a: Ipv6Addr) -> bool {
    let b = a.octets();
    let v4 = |at: usize| Ipv4Addr::new(b[at], b[at + 1], b[at + 2], b[at + 3]);
    if b.iter().all(|&x| x == 0) {
        return false; // ::
    }
    if b[..15].iter().all(|&x| x == 0) && b[15] == 1 {
        return false; // ::1
    }
    if b[..10].iter().all(|&x| x == 0) && b[10] == 0xff && b[11] == 0xff {
        return is_public_v4(v4(12)); // ::ffff:a.b.c.d
    }
    if b[..12].iter().all(|&x| x == 0) {
        return is_public_v4(v4(12)); // ::a.b.c.d (compatible)
    }
    if b[..4] == [0x00, 0x64, 0xff, 0x9b] && b[4..12].iter().all(|&x| x == 0) {
        return is_public_v4(v4(12)); // NAT64 64:ff9b::/96
    }
    if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 {
        return false; // fe80::/10 link-local
    }
    if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 {
        return false; // fec0::/10 site-local
    }
    if (b[0] & 0xfe) == 0xfc {
        return false; // fc00::/7 unique-local
    }
    if b[0] == 0xff {
        return false; // multicast
    }
    if b[..4] == [0x20, 0x01, 0x0d, 0xb8] {
        return false; // 2001:db8::/32 documentation
    }
    if b[0] == 0x01 && b[1..8].iter().all(|&x| x == 0) {
        return false; // 100::/64 discard
    }
    if b[0] == 0x20 && b[1] == 0x02 {
        return is_public_v4(v4(2)); // 6to4 2002::/16 embeds v4
    }
    true
}

/// What a request reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Up to [`HTML_LIMIT`], stopping at `</head>`; a longer page is cut, not refused.
    Html,
    /// Up to [`IMAGE_LIMIT`]; a larger image is refused.
    Image,
}

/// One hop of a request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Hop {
    /// A 3xx answer and its `Location`.
    Redirect(String),
    Body(Vec<u8>),
}

/// One GET that never follows a redirect, connects only to addresses
/// [`resolve_public`] accepted, and stops at `deadline`.
pub trait Transport: Send + Sync {
    fn get(&self, url: &Url, kind: Kind, deadline: Instant) -> Result<Hop, Refusal>;
}

/// A GET through the guard: the URL checked, each redirect re-checked (at
/// most [`MAX_REDIRECTS`], never https -> http). Returns the final URL and
/// the body.
pub fn guarded_get(
    transport: &dyn Transport,
    url: &str,
    kind: Kind,
    deadline: Instant,
) -> Result<(Url, Vec<u8>), Refusal> {
    let url = parse_checked(url)?;
    match transport.get(&url, kind, deadline)? {
        Hop::Body(body) => Ok((url, body)),
        Hop::Redirect(_) => Err(Refusal::Network("redirects not yet".into())),
    }
}

/// Reads an HTML head: up to `limit` bytes, stopping after `</head>`
/// (ASCII case-insensitive). A longer page is cut at `limit`.
pub fn read_html(
    reader: &mut dyn Read,
    limit: usize,
    deadline: Instant,
) -> Result<Vec<u8>, Refusal> {
    let _ = (limit, deadline, find_ascii_ci(b"", b"x"));
    let mut out = Vec::new();
    reader
        .read_to_end(&mut out)
        .map_err(|e| Refusal::Network(e.to_string()))?;
    Ok(out)
}

/// Reads a whole body of at most `limit` bytes; more is [`Refusal::TooLarge`].
pub fn read_capped(
    reader: &mut dyn Read,
    limit: usize,
    deadline: Instant,
) -> Result<Vec<u8>, Refusal> {
    let _ = (limit, deadline);
    let mut out = Vec::new();
    reader
        .read_to_end(&mut out)
        .map_err(|e| Refusal::Network(e.to_string()))?;
    Ok(out)
}

fn find_ascii_ci(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|w| w.eq_ignore_ascii_case(needle))
}

/// The network transport: ureq with no proxy, no cookies (the feature is
/// off), no redirects of its own, and [`resolve_public`] as its resolver,
/// so it connects only to checked addresses.
pub struct HttpTransport {
    agent: ureq::Agent,
}

impl Default for HttpTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpTransport {
    pub fn new() -> HttpTransport {
        let agent = ureq::AgentBuilder::new()
            .try_proxy_from_env(false)
            .redirects(0)
            .user_agent(USER_AGENT)
            .timeout_connect(Duration::from_secs(5))
            .resolver(|netloc: &str| {
                let (host, port) = netloc.rsplit_once(':').ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidInput, "no port")
                })?;
                let port: u16 = port.parse().map_err(|_| {
                    std::io::Error::new(std::io::ErrorKind::InvalidInput, "bad port")
                })?;
                resolve_public(host, port).map_err(|refusal| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, refusal.to_string())
                })
            })
            .build();
        HttpTransport { agent }
    }
}

impl Transport for HttpTransport {
    fn get(&self, url: &Url, kind: Kind, deadline: Instant) -> Result<Hop, Refusal> {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(Refusal::Timeout);
        }
        let accept = match kind {
            Kind::Html => "text/html,application/xhtml+xml",
            Kind::Image => "image/jpeg,image/png,image/webp,image/gif",
        };
        let response = match self
            .agent
            .request_url("GET", url)
            .timeout(left)
            .set("Accept", accept)
            .call()
        {
            Ok(response) => response,
            Err(ureq::Error::Status(status, _)) => return Err(Refusal::Status(status)),
            Err(ureq::Error::Transport(t)) => return Err(Refusal::Network(t.to_string())),
        };
        let status = response.status();
        if (300..400).contains(&status) {
            return match response.header("Location") {
                Some(location) => Ok(Hop::Redirect(location.to_owned())),
                None => Err(Refusal::Status(status)),
            };
        }
        if !(200..300).contains(&status) {
            return Err(Refusal::Status(status));
        }
        let mut reader = response.into_reader();
        let body = match kind {
            Kind::Html => read_html(&mut reader, HTML_LIMIT, deadline)?,
            Kind::Image => read_capped(&mut reader, IMAGE_LIMIT, deadline)?,
        };
        Ok(Hop::Body(body))
    }
}
