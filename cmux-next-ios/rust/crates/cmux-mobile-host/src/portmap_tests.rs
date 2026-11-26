//! `portmap` against in-process fake routers: a PCP/NAT-PMP server (UDP) and
//! an IGD (SSDP over UDP, its description and SOAP over HTTP).

use super::*;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

/// The tests that hold mappings share the process-wide live set that
/// `release_all` drains: one at a time.
static LIVE_SET: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Seconds the fake PCP server grants (0: what was asked), so a test sees a
/// renewal without waiting half an hour. Set under `LIVE_SET` only.
static PCP_GRANT_S: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Ends a test's `release_all` (and its PCP grant) when the test ends, even
/// on a failed assert, so the next test's host runs on.
struct HostRunsOn;

impl Drop for HostRunsOn {
    fn drop(&mut self) {
        PCP_GRANT_S.store(0, Ordering::SeqCst);
        stop_releasing();
    }
}

const PUBLIC: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 7);
const LOOPBACK: Ipv4Addr = Ipv4Addr::LOCALHOST;

/// What a fake router was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Asked {
    Pcp { internal: u16, lifetime: u32 },
    NatPmpAddress,
    NatPmpMap { internal: u16, external: u16, lifetime: u32 },
    Ssdp,
    Description,
    Soap(String),
}

#[derive(Clone, Copy)]
struct Speaks {
    pcp: bool,
    natpmp: bool,
    external: Ipv4Addr,
}

/// A fake PCP/NAT-PMP server on loopback: its port and what it is asked.
async fn fake_pmp(speaks: Speaks) -> (u16, mpsc::UnboundedReceiver<Asked>) {
    let socket = UdpSocket::bind((LOOPBACK, 0)).await.unwrap();
    let port = socket.local_addr().unwrap().port();
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut buffer = [0u8; 1100];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            let request = &buffer[..len];
            let answer = match request.first() {
                Some(&PCP_VERSION) if len >= 60 && request[1] == PCP_MAP => {
                    let internal = u16::from_be_bytes([request[40], request[41]]);
                    let lifetime = u32::from_be_bytes(request[4..8].try_into().unwrap());
                    let _ = tx.send(Asked::Pcp { internal, lifetime });
                    if !speaks.pcp {
                        // RFC 6887 §9: a NAT-PMP-only server answers a PCP
                        // request with UNSUPP_VERSION in its own format.
                        Some(vec![0, 0x80 | PCP_MAP, 0, 1, 0, 0, 0, 0])
                    } else {
                        let mut answer = request[..60].to_vec();
                        answer[1] = 0x80 | PCP_MAP;
                        answer[3] = 0;
                        let grant = PCP_GRANT_S.load(Ordering::SeqCst);
                        if grant != 0 && lifetime != 0 {
                            answer[4..8].copy_from_slice(&grant.to_be_bytes());
                        }
                        let external = 40000 + (internal % 1000);
                        answer[42..44].copy_from_slice(&external.to_be_bytes());
                        answer[44..60].copy_from_slice(&speaks.external.to_ipv6_mapped().octets());
                        Some(answer)
                    }
                }
                // UNSPECIFIED: a router that maps but never says its address.
                Some(0)
                    if speaks.natpmp && len == 2 && request[1] == 0 && !speaks.external.is_unspecified() =>
                {
                    let _ = tx.send(Asked::NatPmpAddress);
                    let mut answer = vec![0, 128, 0, 0, 0, 0, 0, 9];
                    answer.extend_from_slice(&speaks.external.octets());
                    Some(answer)
                }
                Some(0) if speaks.natpmp && len == 12 && request[1] == 1 => {
                    let internal = u16::from_be_bytes([request[4], request[5]]);
                    let external = u16::from_be_bytes([request[6], request[7]]);
                    let lifetime = u32::from_be_bytes(request[8..12].try_into().unwrap());
                    let _ = tx.send(Asked::NatPmpMap { internal, external, lifetime });
                    let granted = if lifetime == 0 { 0 } else { external.max(1) };
                    let mut answer = vec![0, 129, 0, 0, 0, 0, 0, 9];
                    answer.extend_from_slice(&internal.to_be_bytes());
                    answer.extend_from_slice(&granted.to_be_bytes());
                    answer.extend_from_slice(&lifetime.min(7200).to_be_bytes());
                    Some(answer)
                }
                _ => None,
            };
            if let Some(answer) = answer {
                let _ = socket.send_to(&answer, from).await;
            }
        }
    });
    (port, rx)
}

/// A fake IGD on loopback: its SSDP address and what it is asked. `refuse`
/// answers AddPortMapping with that UPnP error code.
async fn fake_igd(refuse: Option<&'static str>) -> (SocketAddr, mpsc::UnboundedReceiver<Asked>) {
    let http = TcpListener::bind((LOOPBACK, 0)).await.unwrap();
    let http_addr = http.local_addr().unwrap();
    let ssdp = UdpSocket::bind((LOOPBACK, 0)).await.unwrap();
    let ssdp_addr = ssdp.local_addr().unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    let ssdp_tx = tx.clone();
    tokio::spawn(async move {
        let mut buffer = [0u8; 2048];
        while let Ok((len, from)) = ssdp.recv_from(&mut buffer).await {
            let text = String::from_utf8_lossy(&buffer[..len]);
            if !text.starts_with("M-SEARCH") || !text.contains("InternetGatewayDevice") {
                continue;
            }
            let _ = ssdp_tx.send(Asked::Ssdp);
            let answer = format!(
                "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\
                 Location: http://{http_addr}/rootDesc.xml\r\n\r\n"
            );
            let _ = ssdp.send_to(answer.as_bytes(), from).await;
        }
    });
    tokio::spawn(async move {
        let description = "<?xml version=\"1.0\"?><root><device><deviceList><device><serviceList>\
            <service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>\
            <controlURL>/ctl/CmnIfCfg</controlURL></service>\
            <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>\
            <controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList></device></root>";
        while let Ok((mut stream, _)) = http.accept().await {
            let tx = tx.clone();
            tokio::spawn(async move {
                let mut request = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let Ok(n) = stream.read(&mut chunk).await else { return };
                    if n == 0 {
                        return;
                    }
                    request.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&request);
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let length = head
                            .lines()
                            .find_map(|line| line.strip_prefix("Content-Length: "))
                            .and_then(|n| n.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        if body.len() >= length {
                            break;
                        }
                    }
                }
                let text = String::from_utf8_lossy(&request).into_owned();
                let (status, body) = if text.starts_with("GET /rootDesc.xml") {
                    let _ = tx.send(Asked::Description);
                    (200, description.to_owned())
                } else if text.starts_with("POST /ctl/IPConn") {
                    let action = text
                        .lines()
                        .find_map(|line| line.strip_prefix("SOAPAction: "))
                        .and_then(|value| value.split('#').nth(1))
                        .map(|value| value.trim_matches('"').to_owned())
                        .unwrap_or_default();
                    let _ = tx.send(Asked::Soap(action.clone()));
                    match (action.as_str(), refuse) {
                        ("GetExternalIPAddress", _) => (
                            200,
                            format!(
                                "<s:Envelope><s:Body><u:GetExternalIPAddressResponse>\
                                <NewExternalIPAddress>{PUBLIC}</NewExternalIPAddress>\
                                </u:GetExternalIPAddressResponse></s:Body></s:Envelope>"
                            ),
                        ),
                        ("AddPortMapping", Some(code)) if !text.contains("<NewLeaseDuration>0<") => (
                            500,
                            format!(
                                "<s:Envelope><s:Body><s:Fault><detail><UPnPError>\
                                <errorCode>{code}</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
                            ),
                        ),
                        _ => (200, "<s:Envelope><s:Body/></s:Envelope>".to_owned()),
                    }
                } else {
                    (404, String::new())
                };
                let answer = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(answer.as_bytes()).await;
            });
        }
    });
    (ssdp_addr, rx)
}

/// A UDP port nothing answers on (bound, so no ICMP refusal either).
async fn silent() -> (UdpSocket, SocketAddr) {
    let socket = UdpSocket::bind((LOOPBACK, 0)).await.unwrap();
    let addr = socket.local_addr().unwrap();
    (socket, addr)
}

fn router(pmp_port: u16, ssdp: SocketAddr) -> Router {
    Router { gateway: LOOPBACK, pmp_port, ssdp, local: LOOPBACK }
}

fn drain(rx: &mut mpsc::UnboundedReceiver<Asked>) -> Vec<Asked> {
    let mut all = Vec::new();
    while let Ok(asked) = rx.try_recv() {
        all.push(asked);
    }
    all
}

async fn next_matching(rx: &mut mpsc::UnboundedReceiver<Asked>, wanted: impl Fn(&Asked) -> bool) -> Asked {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let asked = rx.recv().await.expect("fake router stopped");
            if wanted(&asked) {
                return asked;
            }
        }
    })
    .await
    .expect("the fake router was not asked")
}

#[tokio::test]
async fn pcp_maps_first_and_deletes_on_drop() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (port, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: true, external: PUBLIC }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    let mapping = mapper.map(41234).await.expect("PCP maps");
    assert_eq!(mapping.protocol, "pcp");
    assert_eq!(*mapping.external.borrow(), Some(SocketAddr::new(IpAddr::V4(PUBLIC), 40234)));
    assert_eq!(drain(&mut asked), vec![Asked::Pcp { internal: 41234, lifetime: LIFETIME_S }]);
    drop(mapping);
    assert_eq!(
        next_matching(&mut asked, |_| true).await,
        Asked::Pcp { internal: 41234, lifetime: 0 },
        "dropping the mapping deletes it"
    );
}

#[tokio::test]
async fn natpmp_answers_when_pcp_does_not_and_is_asked_first_next_time() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (port, mut asked) = fake_pmp(Speaks { pcp: false, natpmp: true, external: PUBLIC }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    let started = std::time::Instant::now();
    let mapping = mapper.map(41000).await.expect("NAT-PMP maps");
    // PCP's UNSUPP_VERSION answer ends PCP at once: no 750 ms of retries.
    assert!(started.elapsed() < Duration::from_millis(200), "fell through at once: {:?}", started.elapsed());
    assert_eq!(mapping.protocol, "nat-pmp");
    assert_eq!(*mapping.external.borrow(), Some(SocketAddr::new(IpAddr::V4(PUBLIC), 41000)));
    let first = drain(&mut asked);
    assert!(first.iter().any(|a| matches!(a, Asked::Pcp { .. })), "PCP is tried first: {first:?}");
    assert!(first.contains(&Asked::NatPmpMap { internal: 41000, external: 41000, lifetime: LIFETIME_S }));
    assert!(first.contains(&Asked::NatPmpAddress));
    // The second session's socket: NAT-PMP straight away (cached), no PCP.
    let second = mapper.map(41001).await.expect("NAT-PMP maps again");
    assert_eq!(second.protocol, "nat-pmp");
    let asked_now = drain(&mut asked);
    assert!(!asked_now.iter().any(|a| matches!(a, Asked::Pcp { .. })), "{asked_now:?}");
    drop((mapping, second));
    let deleted = next_matching(&mut asked, |a| matches!(a, Asked::NatPmpMap { lifetime: 0, .. })).await;
    assert!(matches!(deleted, Asked::NatPmpMap { internal: 41000 | 41001, lifetime: 0, .. }));
}

#[tokio::test]
async fn upnp_igd_maps_when_the_router_speaks_neither() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (_quiet, pmp) = silent().await;
    let (ssdp, mut asked) = fake_igd(None).await;
    let mapper = HostMapper::with_router(move || Some(router(pmp.port(), ssdp)));
    let mapping = mapper.map(42000).await.expect("UPnP maps");
    assert_eq!(mapping.protocol, "upnp");
    assert_eq!(*mapping.external.borrow(), Some(SocketAddr::new(IpAddr::V4(PUBLIC), 42000)));
    assert_eq!(
        drain(&mut asked),
        vec![
            Asked::Ssdp,
            Asked::Description,
            Asked::Soap("GetExternalIPAddress".into()),
            Asked::Soap("AddPortMapping".into())
        ]
    );
    // The IGD is cached: the next socket skips the search.
    let again = mapper.map(42001).await.expect("UPnP maps again");
    assert!(!drain(&mut asked).contains(&Asked::Ssdp));
    drop((mapping, again));
    next_matching(&mut asked, |a| *a == Asked::Soap("DeletePortMapping".into())).await;
}

#[tokio::test]
async fn upnp_takes_a_permanent_lease_when_the_router_refuses_a_timed_one() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (_quiet, pmp) = silent().await;
    let (ssdp, _asked) = fake_igd(Some("725")).await;
    let mapper = HostMapper::with_router(move || Some(router(pmp.port(), ssdp)));
    let mapping = mapper.map(42100).await.expect("UPnP maps with lease 0");
    assert_eq!(mapping.protocol, "upnp");
}

#[tokio::test]
async fn a_router_that_maps_nothing_is_not_asked_again() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (_pmp_socket, pmp) = silent().await;
    let (_ssdp_socket, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(pmp.port(), ssdp)));
    assert!(mapper.map(43000).await.is_none());
    let started = std::time::Instant::now();
    assert!(mapper.map(43001).await.is_none());
    assert!(started.elapsed() < Duration::from_millis(100), "cached: {:?}", started.elapsed());
    // Only for NOTHING_RETRY: past it, the router is asked again.
    let key = *lock(&mapper.cache).keys().next().unwrap();
    let past = std::time::Instant::now() - NOTHING_RETRY - Duration::from_secs(1);
    lock(&mapper.cache).insert(key, Known::Nothing(past));
    let started = std::time::Instant::now();
    assert!(mapper.map(43003).await.is_none());
    assert!(started.elapsed() >= Duration::from_millis(100), "asked again: {:?}", started.elapsed());
    // The cache is per (gateway, local address): a network change gives a
    // new key, and the router there is asked again.
    let (port, _asked) = fake_pmp(Speaks { pcp: true, natpmp: false, external: PUBLIC }).await;
    let other = HostMapper {
        router: Box::new(move || Some(Router { local: Ipv4Addr::new(127, 0, 0, 2), ..router(port, ssdp) })),
        cache: Arc::clone(&mapper.cache),
    };
    assert!(other.map(43002).await.is_some());
}

#[tokio::test]
async fn a_natpmp_grant_with_no_public_address_is_given_back() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (port, mut asked) =
        fake_pmp(Speaks { pcp: false, natpmp: true, external: Ipv4Addr::UNSPECIFIED }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    assert!(mapper.map(46000).await.is_none());
    let deleted = next_matching(&mut asked, |a| matches!(a, Asked::NatPmpMap { lifetime: 0, .. })).await;
    assert_eq!(deleted, Asked::NatPmpMap { internal: 46000, external: 46000, lifetime: 0 });
}

#[tokio::test]
async fn a_map_dropped_in_flight_still_deletes_what_the_router_granted() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (port, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: false, external: PUBLIC }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    // A roam or close drops the future before the router answers.
    drop(mapper.map(45000));
    let granted =
        next_matching(&mut asked, |a| matches!(a, Asked::Pcp { lifetime, .. } if *lifetime > 0)).await;
    assert!(matches!(granted, Asked::Pcp { internal: 45000, .. }));
    let deleted = next_matching(&mut asked, |a| matches!(a, Asked::Pcp { lifetime: 0, .. })).await;
    assert_eq!(deleted, Asked::Pcp { internal: 45000, lifetime: 0 });
}

#[tokio::test]
async fn a_mapping_to_a_private_or_cgnat_address_is_not_offered_and_is_deleted() {
    let _one_at_a_time = LIVE_SET.lock().await;
    for external in [Ipv4Addr::new(100, 72, 0, 5), Ipv4Addr::new(192, 168, 0, 2)] {
        let (port, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: false, external }).await;
        let (_quiet, ssdp) = silent().await;
        let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
        assert!(mapper.map(44000).await.is_none(), "{external} is not offered");
        let deleted = next_matching(&mut asked, |a| matches!(a, Asked::Pcp { lifetime: 0, .. })).await;
        assert_eq!(deleted, Asked::Pcp { internal: 44000, lifetime: 0 });
    }
}

#[tokio::test]
async fn release_all_deletes_live_mappings_at_exit() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (port, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: false, external: PUBLIC }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    let mapping = mapper.map(45000).await.expect("maps");
    drain(&mut asked);
    let _runs_on = HostRunsOn;
    release_all(Duration::from_secs(2)).await;
    assert_eq!(
        next_matching(&mut asked, |a| matches!(a, Asked::Pcp { internal: 45000, .. })).await,
        Asked::Pcp { internal: 45000, lifetime: 0 }
    );
    // Its lease then has nothing left to delete.
    drop(mapping);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!drain(&mut asked).contains(&Asked::Pcp { internal: 45000, lifetime: 0 }));
    // A mapping granted once the host is stopping is given back, not held.
    assert!(mapper.map(45001).await.is_none(), "not held while the host stops");
    assert_eq!(
        next_matching(&mut asked, |a| matches!(a, Asked::Pcp { internal: 45001, lifetime: 0 })).await,
        Asked::Pcp { internal: 45001, lifetime: 0 }
    );
    assert!(live_mappings().is_empty());
}

#[tokio::test]
async fn a_renewal_never_puts_a_mapping_back_after_release_all() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let _runs_on = HostRunsOn;
    PCP_GRANT_S.store(1, Ordering::SeqCst);
    let (port, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: false, external: PUBLIC }).await;
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(port, ssdp)));
    let _mapping = mapper.map(47000).await.expect("maps");
    drain(&mut asked);
    // Granted 1 s, it renews within about a second.
    let renewed = |a: &Asked| matches!(a, Asked::Pcp { internal: 47000, lifetime } if *lifetime != 0);
    next_matching(&mut asked, renewed).await;
    release_all(Duration::from_secs(2)).await;
    next_matching(&mut asked, |a| matches!(a, Asked::Pcp { internal: 47000, lifetime: 0 })).await;
    // Several renew periods later, nothing asked for it again.
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let after: Vec<Asked> = drain(&mut asked).into_iter().filter(renewed).collect();
    assert!(after.is_empty(), "renewed after release_all: {after:?}");
}

#[tokio::test]
async fn an_answer_from_another_port_on_the_gateway_is_ignored() {
    let _one_at_a_time = LIVE_SET.lock().await;
    let (real, mut asked) = fake_pmp(Speaks { pcp: true, natpmp: true, external: PUBLIC }).await;
    // Asked on `front`, the real server's answers come back from `side`: the
    // gateway's address, but not its PCP/NAT-PMP port.
    let front = UdpSocket::bind((LOOPBACK, 0)).await.unwrap();
    let front_port = front.local_addr().unwrap().port();
    let side = UdpSocket::bind((LOOPBACK, 0)).await.unwrap();
    tokio::spawn(async move {
        let mut buffer = [0u8; 1100];
        let mut answer = [0u8; 1100];
        while let Ok((len, client)) = front.recv_from(&mut buffer).await {
            let _ = side.send_to(&buffer[..len], (LOOPBACK, real)).await;
            if let Ok(Ok((n, _))) =
                tokio::time::timeout(Duration::from_millis(200), side.recv_from(&mut answer)).await
            {
                let _ = side.send_to(&answer[..n], client).await;
            }
        }
    });
    let (_quiet, ssdp) = silent().await;
    let mapper = HostMapper::with_router(move || Some(router(front_port, ssdp)));
    assert!(mapper.map(48000).await.is_none(), "an answer from another port is not taken");
    // The server was asked (so it did answer), and nothing is held.
    assert!(drain(&mut asked).iter().any(|a| matches!(a, Asked::Pcp { internal: 48000, .. })));
    assert!(live_mappings().is_empty());
}

#[test]
fn kill_switch_reads_the_env() {
    // The parse enabled() runs (the env is process-wide, so it is not set).
    assert!(!enabled_by(Some("0")) && !enabled_by(Some(" 0 ")));
    assert!(enabled_by(Some("1")) && enabled_by(Some("")) && enabled_by(None));
}

#[test]
fn public_addresses_only() {
    for ip in ["203.0.113.7", "8.8.8.8", "100.128.0.1", "100.63.255.255"] {
        assert!(public(ip.parse().unwrap()), "{ip}");
    }
    for ip in [
        "10.0.0.1",
        "172.16.0.1",
        "192.168.1.1",
        "100.64.0.1",
        "100.127.255.255",
        "127.0.0.1",
        "169.254.1.1",
        "0.0.0.0",
        "224.0.0.1",
        "255.255.255.255",
        "2001:db8::1",
    ] {
        assert!(!public(ip.parse().unwrap()), "{ip}");
    }
}

#[test]
fn pcp_request_and_answer_round_trip() {
    let nonce = [7u8; 12];
    let request = pcp_request(Ipv4Addr::new(192, 168, 1, 20), nonce, 51820, None, 3600);
    assert_eq!(request.len(), 60);
    assert_eq!(&request[..4], &[2, 1, 0, 0]);
    assert_eq!(&request[8..24], &Ipv4Addr::new(192, 168, 1, 20).to_ipv6_mapped().octets());
    let mut answer = request;
    answer[1] = 0x81;
    answer[42..44].copy_from_slice(&60000u16.to_be_bytes());
    answer[44..60].copy_from_slice(&PUBLIC.to_ipv6_mapped().octets());
    assert_eq!(pcp_answer(&answer, &nonce, 51820), Some((SocketAddr::new(IpAddr::V4(PUBLIC), 60000), 3600)));
    assert_eq!(pcp_answer(&answer, &[8u8; 12], 51820), None, "another nonce");
    assert_eq!(pcp_answer(&answer, &nonce, 51821), None, "another port");
    answer[3] = 2;
    assert_eq!(pcp_answer(&answer, &nonce, 51820), None, "an error result");
}

#[test]
fn natpmp_wire() {
    assert_eq!(natpmp_request(51820, 51820, 3600), [0, 1, 0, 0, 0xca, 0x6c, 0xca, 0x6c, 0, 0, 0x0e, 0x10]);
    let answer = [0, 129, 0, 0, 0, 0, 0, 1, 0xca, 0x6c, 0xea, 0x60, 0, 0, 0x0e, 0x10];
    assert_eq!(natpmp_map_answer(&answer, 51820), Some((60000, 3600)));
    assert_eq!(natpmp_map_answer(&answer, 1), None);
    let mut refused = answer;
    refused[3] = 3;
    assert_eq!(natpmp_map_answer(&refused, 51820), None);
    assert_eq!(natpmp_address_answer(&[0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 7]), Some(PUBLIC));
}

#[test]
fn igd_description_and_ssdp() {
    let base: SocketAddr = "192.168.1.1:5000".parse().unwrap();
    let ppp = "<root><service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>\
        <controlURL>ctl/PPP</controlURL></service></root>";
    assert_eq!(
        igd_service(ppp, base),
        Some(Igd {
            host: base,
            path: "/ctl/PPP".into(),
            service: "urn:schemas-upnp-org:service:WANPPPConnection:1".into()
        })
    );
    let absolute = "<root><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>\
        <controlURL>http://192.168.1.1:49000/igd</controlURL></service></root>";
    assert_eq!(igd_service(absolute, base).unwrap().host, "192.168.1.1:49000".parse::<SocketAddr>().unwrap());
    // An absolute control URL on another host is refused (the SOAP POST
    // would go to any LAN or loopback address the description names).
    let elsewhere = "<root><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>\
        <controlURL>http://127.0.0.1:8080/admin</controlURL></service></root>";
    assert_eq!(igd_service(elsewhere, base), None);
    assert_eq!(igd_service("<root/>", base), None);
    // An error answer ends an exchange; a success or another opcode does not.
    let pcp_map = [PCP_VERSION, PCP_MAP, 0, 0];
    assert!(refused(&pcp_map, &[0, 0x80 | PCP_MAP, 0, 1]));
    assert!(!refused(&pcp_map, &[PCP_VERSION, 0x80 | PCP_MAP, 0, 0]));
    assert!(!refused(&pcp_map, &[0, 128, 0, 1]));
    assert!(refused(&[0, 1], &[0, 129, 0, 3]));
    assert_eq!(
        ssdp_location("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n").as_deref(),
        Some("http://192.168.1.1:5000/rootDesc.xml")
    );
    assert_eq!(split_url("http://10.0.0.1/desc"), Some(("10.0.0.1:80".parse().unwrap(), "/desc".into())));
    assert_eq!(split_url("https://10.0.0.1/desc"), None);
}

#[test]
fn linux_default_gateway() {
    let table = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n\
        eth0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n\
        eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n";
    assert_eq!(linux_gateway(table), Some(Ipv4Addr::new(192, 168, 1, 1)));
    assert_eq!(linux_gateway("Iface\tDestination\n"), None);
}

#[test]
fn macos_route_dump_gateway() {
    // Two messages with a 92-byte header (rt_msghdr's size on macOS): a
    // host route, then the default route via 192.168.1.1.
    fn message(destination: [u8; 4], gateway: [u8; 4]) -> Vec<u8> {
        let mut out = vec![0u8; 92];
        let sockaddr = |ip: [u8; 4]| {
            let mut sa = vec![16u8, 2, 0, 0];
            sa.extend_from_slice(&ip);
            sa.extend_from_slice(&[0; 8]);
            sa
        };
        out.extend(sockaddr(destination));
        out.extend(sockaddr(gateway));
        let len = out.len() as u16;
        out[..2].copy_from_slice(&len.to_ne_bytes());
        out[12..16].copy_from_slice(&(0x1i32 | 0x2 | 0x4).to_ne_bytes());
        out
    }
    let mut dump = message([10, 0, 0, 5], [10, 0, 0, 1]);
    dump.extend(message([0, 0, 0, 0], [192, 168, 1, 1]));
    assert_eq!(rt_dump_gateway(&dump, 92), Some(Ipv4Addr::new(192, 168, 1, 1)));
    assert_eq!(rt_dump_gateway(&dump[..50], 92), None);
}
