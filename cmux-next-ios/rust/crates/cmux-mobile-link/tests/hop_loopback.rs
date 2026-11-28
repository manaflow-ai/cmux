//! Dial a real WireGuard phone and Mac through an in-process UDP PoP.
use std::{net::SocketAddr, sync::Arc, time::Duration};

use bytes::Bytes;
use cmux_hop_relay::server::{Pop, PopConfig};
use cmux_mobile_link::{
    ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind,
    api::{ApiClient, HopServer},
    dial::{self, SessionEvents, wireguard},
    signaling::SignalPayload,
    testing::{FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile, shaped_counts},
};
use tokio::{net::UdpSocket, sync::oneshot, task::JoinSet, time::timeout};

/// Shape both directions of the phone's outer UDP leg. A delayed packet
/// never blocks the receiver from admitting the next packet to the shaper.
async fn forward(socket: UdpSocket, pop: SocketAddr) {
    let socket = Arc::new(socket);
    let mut phone = None;
    let mut sends = JoinSet::new();
    let mut buf = vec![0; 65_536];
    loop {
        tokio::select! {
            Some(_) = sends.join_next(), if !sends.is_empty() => {}
            received = socket.recv_from(&mut buf) => {
                let (n, from) = received.unwrap();
                let to = if from == pop {
                    let Some(phone) = phone else { continue };
                    phone
                } else {
                    phone = Some(from);
                    pop
                };
                if let Some(delay) = shape_by_profile(false, &from, n) {
                    let datagram = buf[..n].to_vec();
                    let socket = Arc::clone(&socket);
                    sends.spawn(async move {
                        tokio::time::sleep(delay).await;
                        socket.send_to(&datagram, to).await.unwrap();
                    });
                }
            }
        }
    }
}

async fn echo(legacy_mac: bool) {
    let pop = Pop::bind(PopConfig::lab("127.0.0.1:0".parse().unwrap())).await.unwrap();
    let control = pop.local_addr().unwrap();
    let front = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let offered = front.local_addr().unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(async move { pop.run().await.unwrap() });
    tasks.spawn(forward(front, control));
    set_link_profile(Some(LinkProfile::named("lossy-3")), 0x0142_0001);

    let server = FakeSignaling::start(FakeOptions {
        hop_servers: vec![HopServer {
            kind: Some("hop".into()),
            url: Some(format!("hop://{offered}")),
            ticket: None,
        }],
        ..Default::default()
    })
    .await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let (answered, mac_path) = oneshot::channel();
    tasks.spawn(async move {
        let incoming = mac.next_session().await.unwrap();
        let mut first = incoming.first;
        let SignalPayload::WgInit { hop, endpoints, relayed, .. } = &mut first.payload else {
            panic!("expected WG offer")
        };
        let addr = hop.as_ref().expect("PoP address");
        assert!(endpoints.contains(addr) && relayed.contains(addr));
        if legacy_mac {
            *hop = None;
        }
        let events = SessionEvents {
            backend: mac.events(),
            session_id: first.session_id.clone(),
            session: incoming.events,
        };
        let options = DialOptions { include_loopback: true, ..Default::default() };
        let connected = dial::answer(&mac, first, events, &options, LinkConfig::default()).await.unwrap();
        answered.send(connected.path.clone()).unwrap();
        let mut incoming = connected.link.accept().await.unwrap();
        while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
            if incoming.channel.send(bytes).await.is_err() {
                break;
            }
        }
    });

    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    let ice = ApiClient::new(&server.base_url, "user:alice").ice().await.unwrap();
    let options = DialOptions {
        ice_servers: ice.ice_servers,
        relay_only: true,
        timeout: Duration::from_secs(30),
        ..Default::default()
    };
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .expect("dial via PoP");
    let mac_path = mac_path.await.unwrap();
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let payload: Vec<u8> = (0..200_000).map(|i| (i % 251) as u8).collect();
    channel.send(Bytes::from(payload.clone())).await.unwrap();
    let mut echoed = Vec::new();
    while echoed.len() < payload.len() {
        match channel.recv().await {
            Some(ChannelEvent::Data(bytes)) => echoed.extend_from_slice(&bytes),
            other => panic!("echo closed early: {other:?}"),
        }
    }
    assert_eq!(echoed, payload);
    if !legacy_mac {
        // Keep the same application channel across a change of outer socket
        // on each endpoint. The phone re-BINDs its ticket to the allocation.
        for dialer in [true, false] {
            wireguard::roam_session(&connected.session_id, dialer).await.expect("live session");
            let marker = if dialer { "phone roamed" } else { "host roamed" };
            channel.send(Bytes::from_static(marker.as_bytes())).await.unwrap();
            let mut reply = Vec::new();
            while reply.len() < marker.len() {
                let Some(ChannelEvent::Data(bytes)) = channel.recv().await else {
                    panic!("channel lost on roam")
                };
                reply.extend_from_slice(&bytes);
            }
            assert_eq!(reply, marker.as_bytes());
        }
    }
    assert_eq!(*connected.path.borrow(), LinkPath::Hop);
    assert_eq!(*mac_path.borrow(), if legacy_mac { LinkPath::Turn } else { LinkPath::Hop });
    let (delivered, dropped) = shaped_counts();
    let stats = wireguard::hop_stats(&connected.session_id, true).expect("live phone leg");
    eprintln!("legacy_mac={legacy_mac} delivered={delivered} dropped={dropped} stats={stats:?}");
    assert!(dropped > 0 && delivered > dropped);
    assert!(stats.repaired + stats.resent > 0, "the live leg repaired or retransmitted a lost record");
    connected.link.close("done");
    tasks.shutdown().await;
    set_link_profile(None, 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_echo_through_lossy_pop_with_hop_and_plain_mac_legs() {
    // shaped.rs configures one simulated network per process.
    for legacy_mac in [false, true] {
        timeout(Duration::from_secs(55), echo(legacy_mac)).await.expect("bounded lossy echo");
    }
}
