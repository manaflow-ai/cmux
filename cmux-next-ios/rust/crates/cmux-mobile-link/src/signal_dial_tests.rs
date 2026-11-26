//! The signaling dial on paused time: an injected connector, no network and no wall time.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use cmux_braid_path::LastGood;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use super::{connect_remembered, host_port};

const fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[tokio::test(start_paused = true)]
async fn a_reconnect_starts_at_the_address_that_won_last_time() {
    let v6: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
    let v4: SocketAddr = "192.0.2.1:443".parse().unwrap();
    let memory = LastGood::new(Duration::from_secs(60));
    // IPv6 is black-holed (its SYN never answers); IPv4 connects in 25 ms.
    let dial = |address: SocketAddr| async move {
        if address.is_ipv6() {
            std::future::pending::<()>().await;
        }
        tokio::time::sleep(ms(25)).await;
        Ok::<_, io::Error>(address)
    };
    // The resolver's order puts IPv4 first; the dial still tries IPv6 first, and waits the
    // full 400 ms stagger once. Every reconnect after starts at IPv4 and takes its 25 ms.
    for expected in [425, 25, 25] {
        let began = Instant::now();
        let won = connect_remembered(&memory, "API.example", 443, &[v4, v6], dial).await.unwrap();
        assert_eq!(won, v4);
        assert_eq!(began.elapsed(), ms(expected));
    }
    assert_eq!(memory.get(&("api.example".to_owned(), 443)).unwrap().target, v4);
}

#[tokio::test(start_paused = true)]
async fn a_remembered_address_that_dies_is_left_after_one_short_stagger() {
    let v6: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
    let v4: SocketAddr = "192.0.2.1:443".parse().unwrap();
    let memory = LastGood::new(Duration::from_secs(60));
    memory.record(("api.example".to_owned(), 443), v4, ms(20));
    // The network changed: IPv4 is gone now, IPv6 answers in 40 ms. The backup starts after
    // the 100 ms floor (1.5 x 20 ms is under it), not the 400 ms default.
    let dial = |address: SocketAddr| async move {
        if address.is_ipv4() {
            std::future::pending::<()>().await;
        }
        tokio::time::sleep(ms(40)).await;
        Ok::<_, io::Error>(address)
    };
    let began = Instant::now();
    let won = connect_remembered(&memory, "api.example", 443, &[v4, v6], dial).await.unwrap();
    assert_eq!(won, v6);
    assert_eq!(began.elapsed(), ms(140));
    assert_eq!(memory.get(&("api.example".to_owned(), 443)).unwrap().target, v6);
}

#[test]
fn the_host_and_port_come_from_the_signal_url() {
    let port = |url: &str| host_port(&url.into_client_request().unwrap()).unwrap();
    assert_eq!(port("wss://API.example/v1/teams/t/signal"), ("api.example".to_owned(), 443));
    assert_eq!(port("ws://127.0.0.1:8787/v1/teams/t/signal"), ("127.0.0.1".to_owned(), 8787));
    assert_eq!(port("ws://[::1]:9/x"), ("::1".to_owned(), 9));
    assert_eq!(port("ws://host.example/x"), ("host.example".to_owned(), 80));
}
