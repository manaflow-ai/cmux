use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::{
    DNS_GRACE, FORMAT_VERSION, Lookup, MAX_ADDRS, MAX_HOSTS, Resolver, RouteLiterals, TTL, decode, now_secs,
    split_host_port,
};

/// What the fake resolver does.
#[derive(Clone)]
enum Answer {
    With(Vec<IpAddr>),
    Fail,
    Hang,
}

struct Fake {
    answer: Mutex<Answer>,
    asked: AtomicU32,
}

impl Fake {
    fn new(answer: Answer) -> Arc<Self> {
        Arc::new(Self { answer: Mutex::new(answer), asked: AtomicU32::new(0) })
    }

    fn set(&self, answer: Answer) {
        *self.answer.lock().unwrap() = answer;
    }
}

impl Resolver for Fake {
    fn lookup(&self, _host: &str) -> Lookup {
        self.asked.fetch_add(1, Ordering::Relaxed);
        let answer = self.answer.lock().unwrap().clone();
        Box::pin(async move {
            match answer {
                Answer::With(found) => Ok(found),
                Answer::Fail => Err(std::io::Error::other("SERVFAIL")),
                Answer::Hang => std::future::pending().await,
            }
        })
    }
}

fn ip(last: u8) -> IpAddr {
    IpAddr::V4(Ipv4Addr::new(192, 0, 2, last))
}

fn sa(text: &str) -> std::net::SocketAddr {
    text.parse().unwrap()
}

fn memory(fake: &Arc<Fake>) -> Arc<RouteLiterals> {
    Arc::new(RouteLiterals::new(Arc::clone(fake) as Arc<dyn Resolver>))
}

#[test]
fn host_and_port_parse_every_form() {
    assert_eq!(split_host_port("turn.example:3478", 1), Some(("turn.example".into(), 3478)));
    assert_eq!(split_host_port("turn.example", 1), Some(("turn.example".into(), 1)));
    assert_eq!(split_host_port("[2001:db8::1]:443", 1), Some(("2001:db8::1".into(), 443)));
    assert_eq!(split_host_port("2001:db8::1", 7), Some(("2001:db8::1".into(), 7)));
    assert_eq!(split_host_port("t.example:nope", 1), None);
}

#[tokio::test]
async fn a_literal_needs_no_resolver() {
    let fake = Fake::new(Answer::Fail);
    let routes = memory(&fake);
    let found = routes.resolve("127.0.0.1:3478", 0).await.unwrap();
    assert_eq!(found, vec![sa("127.0.0.1:3478")]);
    assert_eq!(routes.resolve("[::1]:443", 0).await.unwrap(), vec![sa("[::1]:443")]);
    assert_eq!(fake.asked.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn with_nothing_remembered_a_dns_failure_fails() {
    let routes = memory(&Fake::new(Answer::Fail));
    assert!(routes.resolve("turn.example:3478", 0).await.is_err());
    assert!(routes.remembered("turn.example").is_none());
}

/// DNS down (an answer that fails, or none at all): the remembered literals still dial, the
/// hanging case within the grace.
#[tokio::test]
async fn dns_down_dials_the_remembered_literals() {
    let fake = Fake::new(Answer::With(vec![ip(1)]));
    let routes = memory(&fake);
    assert_eq!(routes.resolve("TURN.example.:3478", 0).await.unwrap(), vec![sa("192.0.2.1:3478")]);
    fake.set(Answer::Fail);
    assert_eq!(routes.resolve("turn.example:443", 0).await.unwrap(), vec![sa("192.0.2.1:443")]);
    fake.set(Answer::Hang);
    let started = Instant::now();
    assert_eq!(routes.resolve("turn.example:3478", 0).await.unwrap(), vec![sa("192.0.2.1:3478")]);
    let took = started.elapsed();
    assert!(took < DNS_GRACE + Duration::from_millis(400), "{took:?}");
    // The hanging refresh is still out: a second lookup does not stack another, nor wait.
    let started = Instant::now();
    routes.resolve("turn.example:3478", 0).await.unwrap();
    assert!(started.elapsed() < DNS_GRACE / 2, "{:?}", started.elapsed());
}

/// Healthy DNS wins over a stale literal (the server moved), and its answer refreshes the
/// memory.
#[tokio::test]
async fn a_dns_answer_wins_and_refreshes_the_memory() {
    let fake = Fake::new(Answer::With(vec![ip(1)]));
    let routes = memory(&fake);
    routes.resolve("stun.example", 3478).await.unwrap();
    fake.set(Answer::With(vec![ip(9), ip(8)]));
    let started = Instant::now();
    let found = routes.resolve("stun.example", 3478).await.unwrap();
    assert!(started.elapsed() < DNS_GRACE, "DNS answered at once, the grace was not waited out");
    assert_eq!(found[0].ip(), ip(9));
    assert_eq!(routes.remembered("stun.example"), Some(vec![ip(9), ip(8)]));
}

#[tokio::test]
async fn a_reached_address_goes_first_and_survives_a_refresh_naming_it() {
    let fake = Fake::new(Answer::With(vec![ip(1), ip(2), ip(3)]));
    let routes = memory(&fake);
    routes.resolve("turn.example", 1).await.unwrap();
    routes.confirm("turn.example", ip(2));
    assert_eq!(routes.remembered("turn.example"), Some(vec![ip(2), ip(1), ip(3)]));
    routes.store("turn.example", &[ip(1), ip(2), ip(3)]);
    assert_eq!(routes.remembered("turn.example").unwrap()[0], ip(2));
    routes.store("turn.example", &[ip(4)]);
    assert_eq!(routes.remembered("turn.example"), Some(vec![ip(4)]));
}

#[test]
fn the_memory_is_bounded() {
    let routes = RouteLiterals::new(Fake::new(Answer::Fail));
    let many: Vec<IpAddr> = (1..=20).map(ip).collect();
    routes.store("turn.example", &many);
    assert_eq!(routes.remembered("turn.example").unwrap().len(), MAX_ADDRS);
    for host in 0..MAX_HOSTS * 3 {
        routes.store(&format!("h{host}.example"), &[ip(1)]);
    }
    assert!(routes.lock().hosts.len() <= MAX_HOSTS);
}

/// The file round trips; entries past the TTL, a file of an older shape (no `hosts`), one
/// that does not parse and a newer version with fields this build does not know all load.
#[test]
fn the_file_loads_every_version() {
    let routes = RouteLiterals::new(Fake::new(Answer::Fail));
    routes.store("turn.example", &[ip(1), "2001:db8::1".parse().unwrap()]);
    let text = routes.encoded();
    assert!(text.contains(&format!("\"version\":{FORMAT_VERSION}")), "{text}");
    let loaded = decode(&text);
    assert_eq!(loaded["turn.example"].addrs.len(), 2);

    assert!(decode("{}").is_empty());
    assert!(decode("{\"version\":0}").is_empty());
    assert!(decode("not json").is_empty());
    assert!(decode("{\"version\":1,\"hosts\":{\"t.example\":{\"at\":1}}}").is_empty());
    let old = now_secs() - TTL.as_secs() - 1;
    assert!(
        decode(&format!(
            "{{\"version\":1,\"hosts\":{{\"t.example\":{{\"addrs\":[\"192.0.2.1\"],\"at\":{old}}}}}}}"
        ))
        .is_empty()
    );
    let now = now_secs();
    let newer = format!(
        "{{\"version\":9,\"extra\":true,\"hosts\":{{\"T.example\":{{\"addrs\":[\"192.0.2.1\"],\"at\":{now},\"port\":3478}},\"bad\":7}}}}"
    );
    let loaded = decode(&newer);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded["t.example"].addrs, vec![ip(1)]);
}

#[test]
fn set_file_persists_and_reloads() {
    let dir = std::env::temp_dir().join(format!("route-literals-{}", uuid::Uuid::new_v4()));
    let path = dir.join("route-literals.json");
    let first = RouteLiterals::new(Fake::new(Answer::Fail));
    assert_eq!(first.set_file(&path), 0);
    first.store("turn.example", &[ip(5)]);
    let second = RouteLiterals::new(Fake::new(Answer::Fail));
    assert_eq!(second.set_file(&path), 1);
    assert_eq!(second.remembered("turn.example"), Some(vec![ip(5)]));
    second.clear();
    assert_eq!(RouteLiterals::new(Fake::new(Answer::Fail)).set_file(&path), 0);
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&dir).unwrap();
}
