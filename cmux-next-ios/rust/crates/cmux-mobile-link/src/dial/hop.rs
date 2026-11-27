//! UDP adapter for a hop/1 leg. The leg owns ordering, repair, pacing and
//! latest-wins. Both endpoints use this same driver.
use super::{DialOptions, SendClass};
use crate::link_stat::HopStats;
use cmux_transport::hop::{HopClass, HopMsg, Leg, LegConfig, Record};
use std::io;
use std::net::{SocketAddr, UdpSocket as StdUdp};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot};

const ALLOCATION_TIMEOUT: Duration = Duration::from_secs(3);
const BIND_RETRY: Duration = Duration::from_millis(250);

pub(super) fn configured(options: &DialOptions) -> bool {
    !options.block_udp && options.ice_servers.iter().any(|server| server.hop_config().is_some())
}

struct Shared {
    leg: Mutex<Leg>,
    wake: Notify,
}

/// A session's negotiated hop leg. Records submitted here already went
/// through WireGuard on this tunnel.
#[derive(Clone)]
pub struct HopSender(Weak<Shared>);

impl HopSender {
    fn push(&self, record: Record) -> bool {
        let Some(shared) = self.0.upgrade() else { return false };
        let accepted =
            shared.leg.lock().unwrap_or_else(PoisonError::into_inner).send(record, Instant::now()).is_ok();
        shared.wake.notify_one();
        accepted
    }

    pub(super) fn send(&self, datagram: &[u8], class: SendClass) -> bool {
        let class = match class {
            SendClass::Control => HopClass::Control,
            SendClass::Input => HopClass::Input,
            SendClass::Bulk => HopClass::Bulk,
            SendClass::Media => HopClass::Media,
        };
        self.push(Record::new(class, datagram.to_vec()))
    }

    /// Queue the encrypted data for one authenticated state update. The
    /// producer supplies the same stream key and sequence in the inner record.
    pub fn send_latest(&self, key: u32, seq: u32, encrypted: &[u8]) -> bool {
        cmux_transport::classify(encrypted) == cmux_transport::DatagramClass::WireGuardData
            && encrypted.len() > cmux_transport::classify::WG_DATA_MIN_LEN
            && self.push(Record::tagged(key, seq, encrypted.to_vec()))
    }

    pub(super) fn stats(&self) -> Option<HopStats> {
        let shared = self.0.upgrade()?;
        let s = shared.leg.lock().unwrap_or_else(PoisonError::into_inner).stats();
        Some(HopStats {
            srtt_ms: u64::try_from(s.srtt.as_millis()).unwrap_or(u64::MAX),
            loss_permille: s.loss_permille,
            resent: s.resent,
            repaired: s.repaired_by_nack.saturating_add(s.repaired_by_fec),
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Rebind {
    NewAddress(SocketAddr),
    TicketRefused,
}

pub(super) struct HopCarrier {
    pub(super) relayed: SocketAddr,
    pub(super) sender: HopSender,
    pub(super) inbound: mpsc::Receiver<Vec<u8>>,
    roam: mpsc::UnboundedSender<oneshot::Sender<Rebind>>,
    driver: tokio::task::JoinHandle<()>,
}

impl Drop for HopCarrier {
    fn drop(&mut self) {
        self.driver.abort();
    }
}

fn connected(addr: SocketAddr) -> io::Result<UdpSocket> {
    let socket = StdUdp::bind(if addr.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
    socket.set_nonblocking(true)?;
    socket.connect(addr)?;
    UdpSocket::from_std(socket)
}

async fn bind(socket: &UdpSocket, request: &[u8]) -> io::Result<SocketAddr> {
    let mut reply = [0; 128];
    loop {
        socket.send(request).await?;
        let deadline = tokio::time::Instant::now() + BIND_RETRY;
        while let Ok(got) = tokio::time::timeout_at(deadline, socket.recv(&mut reply)).await {
            match HopMsg::decode(&reply[..got?]) {
                Ok(HopMsg::BindOk { addr, lifetime_s }) if addr.port() != 0 && lifetime_s > 0 => {
                    return Ok(addr);
                }
                Ok(HopMsg::Error { code: 1 }) => {
                    return Err(io::Error::new(io::ErrorKind::PermissionDenied, "hop ticket refused"));
                }
                Ok(HopMsg::Error { .. }) => return Err(io::Error::other("hop BIND rejected")),
                _ => {}
            }
        }
    }
}

pub(super) async fn allocate(options: &DialOptions) -> Option<HopCarrier> {
    if options.block_udp {
        return None;
    }
    let mut servers = tokio::task::JoinSet::new();
    for (url, ticket) in options.ice_servers.iter().filter_map(|entry| entry.hop_config()) {
        let Some(authority) = url.strip_prefix("hop://") else { continue };
        if authority.contains(['/', '?', '#', '@']) || authority.is_empty() {
            continue;
        }
        let Ok(request) = (HopMsg::Bind { ticket: ticket.as_bytes().to_vec() }).encode() else { continue };
        let authority = authority.to_owned();
        servers.spawn(async move {
            // A ticket identifies one allocation. Concurrent BINDs on different
            // sockets would move it back and forth between source ports.
            let addresses: Vec<_> = tokio::net::lookup_host(authority).await.ok()?.collect();
            let deadline = tokio::time::Instant::now() + ALLOCATION_TIMEOUT;
            for (index, &addr) in addresses.iter().enumerate() {
                let Ok(socket) = connected(addr) else { continue };
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let timeout = left / (addresses.len() - index) as u32;
                if let Ok(Ok(relayed)) = tokio::time::timeout(timeout, bind(&socket, &request)).await {
                    return Some(HopCarrier::start(socket, addr, relayed, Some(request)));
                }
            }
            None
        });
    }
    tokio::time::timeout(ALLOCATION_TIMEOUT, async {
        while let Some(result) = servers.join_next().await {
            if let Ok(Some(carrier)) = result {
                return Some(carrier);
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
}

fn fresh_leg() -> Leg {
    let mut seed = [0; 4];
    getrandom::fill(&mut seed).expect("operating system randomness");
    Leg::new(LegConfig::default(), u32::from_ne_bytes(seed), Instant::now())
}

impl HopCarrier {
    pub(super) fn peer(addr: SocketAddr) -> io::Result<Self> {
        Ok(Self::start(connected(addr)?, addr, addr, None))
    }

    fn start(
        socket: UdpSocket,
        addr: SocketAddr,
        relayed: SocketAddr,
        bind_request: Option<Vec<u8>>,
    ) -> Self {
        let shared = Arc::new(Shared { leg: Mutex::new(fresh_leg()), wake: Notify::new() });
        let sender = HopSender(Arc::downgrade(&shared));
        let (tx, inbound) = mpsc::channel(256);
        let (roam, mut changed) = mpsc::unbounded_channel::<oneshot::Sender<Rebind>>();
        let driver = tokio::spawn(async move {
            let mut socket = socket;
            let mut allocation = relayed;
            let mut buf = vec![0; 65_536];
            loop {
                // Bound work per turn so input and roam can also run on a busy leg.
                for _ in 0..64 {
                    let packet = shared
                        .leg
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .poll_transmit(Instant::now());
                    let Some(packet) = packet else { break };
                    let _ = socket.send(&packet).await;
                }
                let deadline = shared.leg.lock().unwrap_or_else(PoisonError::into_inner).poll_timeout();
                tokio::select! {
                    _ = shared.wake.notified() => {}
                    _ = async {
                        if let Some(at) = deadline { tokio::time::sleep_until(at.into()).await }
                        else { std::future::pending().await }
                    } => {}
                    change = changed.recv() => {
                        let Some(new_port) = change else { break };
                        let Ok(fresh) = connected(addr) else { continue };
                        if let Some(request) = &bind_request {
                            let reply = tokio::time::timeout(ALLOCATION_TIMEOUT, bind(&fresh, request)).await;
                            let address = match reply {
                                Ok(Ok(address)) => address,
                                Ok(Err(error)) if error.kind() == io::ErrorKind::PermissionDenied => {
                                    let _ = new_port.send(Rebind::TicketRefused);
                                    continue;
                                }
                                _ => continue,
                            };
                            if address != allocation {
                                // The old allocation aged out while the phone slept.
                                // A fresh relay also has a fresh peer sequence space.
                                *shared.leg.lock().unwrap_or_else(PoisonError::into_inner) = fresh_leg();
                                allocation = address;
                                let _ = new_port.send(Rebind::NewAddress(address));
                            }
                        }
                        socket = fresh;
                    }
                    ready = socket.recv(&mut buf) => {
                        if let Ok(n) = ready {
                            let records = shared.leg.lock().unwrap_or_else(PoisonError::into_inner)
                                .handle(&buf[..n], Instant::now());
                            for item in records { let _ = tx.try_send(item.record.bytes); }
                        }
                    }
                }
            }
        });
        Self { relayed, sender, inbound, roam, driver }
    }

    pub(super) fn rebind(&self, new_port: oneshot::Sender<Rebind>) {
        let _ = self.roam.send(new_port);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::IceServer;

    /// Ignore control traffic (e.g. the leg's periodic PING).
    async fn next(socket: &UdpSocket, kind: u8) -> (HopMsg, SocketAddr) {
        tokio::time::timeout(Duration::from_secs(3), async {
            let mut buf = [0; 2048];
            loop {
                let (n, from) = socket.recv_from(&mut buf).await.unwrap();
                if n >= 2 && buf[1] == kind {
                    return (HopMsg::decode(&buf[..n]).unwrap(), from);
                }
            }
        })
        .await
        .expect("hop message arrived")
    }

    #[tokio::test]
    async fn rebind_preserves_port_and_sequence_and_latest_requires_explicit_tag() {
        use cmux_transport::hop::{StreamTag, TYPE_BIND, TYPE_DATA};
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = server.local_addr().unwrap();
        let relayed: SocketAddr = "127.0.0.1:52013".parse().unwrap();
        let reply = HopMsg::BindOk { addr: relayed, lifetime_s: 60 }.encode().unwrap();
        let options = DialOptions {
            ice_servers: vec![IceServer::hop(format!("hop://{addr}"), "ticket")],
            ..Default::default()
        };
        let allocation = tokio::spawn(async move { allocate(&options).await });
        let (request, first) = next(&server, TYPE_BIND).await;
        assert_eq!(request, HopMsg::Bind { ticket: b"ticket".to_vec() });
        // Lose the first BIND_OK. The allocation retries with the same identity.
        assert_eq!(next(&server, TYPE_BIND).await, (request.clone(), first));
        server.send_to(&reply, first).await.unwrap();
        let carrier = allocation.await.unwrap().unwrap();
        assert_eq!(carrier.relayed, relayed);
        let mut data = vec![0; 64];
        data[0] = 4;
        assert!(carrier.sender.send(&data, SendClass::Input));
        let (before, source) = next(&server, TYPE_DATA).await;
        assert_eq!(source, first);
        let HopMsg::Data { seq, records } = before else { unreachable!() };
        assert_eq!(records, vec![Record::new(HopClass::Input, data.clone())]);
        let (changed, reply_port) = oneshot::channel();
        carrier.rebind(changed);
        let (again, second) = next(&server, TYPE_BIND).await;
        assert_eq!(again, request);
        assert_ne!(first, second);
        server.send_to(&reply, second).await.unwrap();
        assert!(!carrier.sender.send_latest(8, 9, &data[..2]));
        assert!(carrier.sender.send_latest(8, 9, &data));
        let (after, source) = next(&server, TYPE_DATA).await;
        assert_eq!(source, second);
        let HopMsg::Data { seq: next_seq, records } = after else { unreachable!() };
        assert!(reply_port.await.is_err(), "a live allocation keeps its port");
        assert_eq!(next_seq, seq.wrapping_add(1));
        assert_eq!(
            records,
            vec![Record {
                class: HopClass::Interactive,
                tag: Some(StreamTag { key: 8, seq: 9 }),
                bytes: data
            }]
        );
        let (changed, reply_port) = oneshot::channel();
        carrier.rebind(changed);
        let (_, third) = next(&server, TYPE_BIND).await;
        let replacement: SocketAddr = "127.0.0.1:52321".parse().unwrap();
        let fresh = HopMsg::BindOk { addr: replacement, lifetime_s: 60 }.encode().unwrap();
        server.send_to(&fresh, third).await.unwrap();
        assert_eq!(reply_port.await.unwrap(), Rebind::NewAddress(replacement));

        let (changed, result) = oneshot::channel();
        carrier.rebind(changed);
        let (_, fourth) = next(&server, TYPE_BIND).await;
        server.send_to(&HopMsg::Error { code: 1 }.encode().unwrap(), fourth).await.unwrap();
        assert_eq!(result.await.unwrap(), Rebind::TicketRefused);
    }
}
