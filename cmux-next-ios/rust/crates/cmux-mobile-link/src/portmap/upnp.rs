//! UPnP-IGD: SSDP discovery of the gateway's WANIPConnection / WANPPPConnection service, then
//! SOAP `AddPortMapping`, `GetExternalIPAddress` and `DeletePortMapping` over HTTP. Only the
//! default gateway is trusted: a description or control URL naming another host is refused.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};

use super::{Failure, Granted};

/// The most an HTTP answer may be.
const MAX_BODY: usize = 64 * 1024;
/// The wait for one HTTP exchange.
const HTTP_WAIT: Duration = Duration::from_secs(3);

/// A discovered gateway service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Service {
    /// Where the control URL is served (the gateway).
    pub host: SocketAddr,
    pub path: String,
    /// The service type, as the SOAP action names it.
    pub kind: String,
}

/// The `LOCATION` of an SSDP answer.
pub(super) fn parse_location(packet: &str) -> Option<String> {
    packet.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim().eq_ignore_ascii_case("location").then(|| value.trim().to_owned())
    })
}

/// `http://ip:port/path` into the address and path; only an IPv4 literal.
pub(super) fn split_url(url: &str) -> Option<(SocketAddr, String)> {
    let rest = url.strip_prefix("http://")?;
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], rest[index..].to_owned()),
        None => (rest, "/".to_owned()),
    };
    let address = if authority.contains(':') {
        authority.parse::<SocketAddr>().ok()?
    } else {
        SocketAddr::new(authority.parse::<Ipv4Addr>().ok()?.into(), 80)
    };
    Some((address, path))
}

fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{name}>");
    let close = format!("</{name}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].trim())
}

/// The WAN connection service of a device description fetched from `location`.
pub(super) fn parse_description(xml: &str, location: SocketAddr) -> Option<Service> {
    let mut rest = xml;
    let base = tag(xml, "URLBase").and_then(split_url);
    while let Some(start) = rest.find("<service>") {
        let block_end = rest[start..].find("</service>").map(|end| start + end)?;
        let block = &rest[start..block_end];
        rest = &rest[block_end..];
        let Some(kind) = tag(block, "serviceType") else { continue };
        if !(kind.contains("WANIPConnection") || kind.contains("WANPPPConnection")) {
            continue;
        }
        let control = tag(block, "controlURL")?;
        let (host, path) = if control.starts_with("http://") {
            split_url(control)?
        } else {
            let path = if control.starts_with('/') { control.to_owned() } else { format!("/{control}") };
            (base.as_ref().map_or(location, |(host, _)| *host), path)
        };
        return Some(Service { host, path, kind: kind.to_owned() });
    }
    None
}

async fn http(to: SocketAddr, request: String) -> Option<(u16, String, Ipv4Addr)> {
    let work = async {
        let mut stream = TcpStream::connect(to).await.ok()?;
        let local = match stream.local_addr().ok()? {
            SocketAddr::V4(addr) => *addr.ip(),
            SocketAddr::V6(_) => Ipv4Addr::UNSPECIFIED,
        };
        stream.write_all(request.as_bytes()).await.ok()?;
        let mut body = Vec::new();
        let _ = (&mut stream).take(MAX_BODY as u64).read_to_end(&mut body).await;
        let text = String::from_utf8_lossy(&body).into_owned();
        let status = text.split_whitespace().nth(1)?.parse().ok()?;
        let content = text.split_once("\r\n\r\n").map_or(String::new(), |(_, body)| body.to_owned());
        Some((status, content, local))
    };
    tokio::time::timeout(HTTP_WAIT, work).await.ok().flatten()
}

fn get_request(host: SocketAddr, path: &str) -> String {
    format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
}

fn soap_request(service: &Service, action: &str, arguments: &str) -> String {
    let body = format!(
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\
         <u:{action} xmlns:u=\"{kind}\">{arguments}</u:{action}></s:Body></s:Envelope>",
        kind = service.kind
    );
    format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: text/xml; charset=\"utf-8\"\r\n\
         SOAPAction: \"{kind}#{action}\"\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
        path = service.path,
        host = service.host,
        kind = service.kind,
        len = body.len()
    )
}

/// Discover the gateway's WAN service: SSDP search sent to `ssdp` and to the gateway itself,
/// then its description.
pub(super) async fn discover(gateway: Ipv4Addr, ssdp: SocketAddr, wait: Duration) -> Option<Service> {
    let socket = UdpSocket::bind("0.0.0.0:0").await.ok()?;
    let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n\
                  ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n";
    let _ = socket.send_to(search.as_bytes(), ssdp).await;
    let _ = socket.send_to(search.as_bytes(), SocketAddr::new(gateway.into(), 1900)).await;
    let deadline = tokio::time::Instant::now() + wait;
    let mut buffer = [0u8; 2048];
    while let Ok(Ok((len, from))) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await {
        if from.ip() != std::net::IpAddr::V4(gateway) {
            continue;
        }
        let text = String::from_utf8_lossy(&buffer[..len]);
        let Some((host, path)) = parse_location(&text).as_deref().and_then(split_url) else { continue };
        if host.ip() != std::net::IpAddr::V4(gateway) {
            continue;
        }
        let Some((200, xml, _)) = http(host, get_request(host, &path)).await else { continue };
        if let Some(service) = parse_description(&xml, host)
            && service.host.ip() == std::net::IpAddr::V4(gateway)
        {
            return Some(service);
        }
    }
    None
}

fn error_code(body: &str) -> u32 {
    tag(body, "errorCode").and_then(|code| code.parse().ok()).unwrap_or(0)
}

/// Map UDP `internal` to `external_port` for `lifetime` seconds. A gateway that only takes
/// permanent mappings (error 725) is asked for one (lease 0), which the caller then deletes.
pub(super) async fn add(
    service: &Service,
    internal: u16,
    external_port: u16,
    lifetime: u32,
) -> Result<Granted, Failure> {
    let mut lease = lifetime;
    let mut port = external_port;
    for _ in 0..4 {
        let local = {
            let probe = TcpStream::connect(service.host).await.map_err(|_| Failure::Silent)?;
            match probe.local_addr() {
                Ok(SocketAddr::V4(addr)) => *addr.ip(),
                _ => return Err(Failure::Silent),
            }
        };
        let arguments = format!(
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>{port}</NewExternalPort>\
             <NewProtocol>UDP</NewProtocol><NewInternalPort>{internal}</NewInternalPort>\
             <NewInternalClient>{local}</NewInternalClient><NewEnabled>1</NewEnabled>\
             <NewPortMappingDescription>cmux</NewPortMappingDescription>\
             <NewLeaseDuration>{lease}</NewLeaseDuration>"
        );
        let (status, body, _) = http(service.host, soap_request(service, "AddPortMapping", &arguments))
            .await
            .ok_or(Failure::Silent)?;
        if status == 200 {
            let ip = external_ip(service).await?;
            return Ok(Granted {
                external: SocketAddrV4::new(ip, port),
                lifetime: Duration::from_secs(if lease == 0 { 3600 } else { u64::from(lease) }),
            });
        }
        match error_code(&body) {
            725 => lease = 0,
            // Conflict with another mapping, or a port the gateway reserves: another port.
            718 | 724 | 729 => port = port.wrapping_add(1).max(1024),
            code => return Err(Failure::Refused(code)),
        }
    }
    Err(Failure::Refused(718))
}

async fn external_ip(service: &Service) -> Result<Ipv4Addr, Failure> {
    let (status, body, _) =
        http(service.host, soap_request(service, "GetExternalIPAddress", "")).await.ok_or(Failure::Silent)?;
    if status != 200 {
        return Err(Failure::Refused(error_code(&body)));
    }
    tag(&body, "NewExternalIPAddress").and_then(|ip| ip.parse().ok()).ok_or(Failure::Refused(0))
}

/// Delete the mapping of `external_port`.
pub(super) async fn delete(service: &Service, external_port: u16) {
    let arguments = format!(
        "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external_port}</NewExternalPort>\
         <NewProtocol>UDP</NewProtocol>"
    );
    let _ = http(service.host, soap_request(service, "DeletePortMapping", &arguments)).await;
}
