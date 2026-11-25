use super::*;
use cmux_transport::LocalNetwork;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::net::TcpListener;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn the_value_is_region_colon_ms_in_region_order() {
    let netcheck =
        Netcheck::from_rtts([("weur", ms(80)), ("wnam", ms(31)), ("enam", Duration::from_micros(72_400))]);
    assert_eq!(netcheck.value().as_deref(), Some("wnam:31,enam:72,weur:80"));
    assert_eq!(netcheck.home(), Some("wnam"));
}

#[test]
fn unknown_regions_are_dropped_and_none_answered_is_no_value() {
    let netcheck = Netcheck::from_rtts([("mars", ms(1))]);
    assert_eq!(netcheck.value(), None);
    assert_eq!(netcheck.home(), None);
}

#[test]
fn a_sub_millisecond_rtt_reports_one_and_halves_round() {
    let netcheck =
        Netcheck::from_rtts([("oc", Duration::from_micros(200)), ("me", Duration::from_micros(4_500))]);
    assert_eq!(netcheck.value().as_deref(), Some("oc:1,me:5"));
}

#[test]
fn the_home_region_is_the_least_rtt_first_in_order_on_a_tie() {
    let netcheck = Netcheck::from_rtts([("apac", ms(12)), ("oc", ms(9)), ("afr", ms(9)), ("wnam", ms(150))]);
    assert_eq!(netcheck.home(), Some("oc"));
}

#[test]
fn every_region_at_its_longest_fits_the_workers_limit() {
    let netcheck = Netcheck::from_rtts(REGIONS.iter().map(|r| (*r, ms(4_999))));
    let value = netcheck.value().unwrap();
    assert!(value.len() <= MAX_VALUE_LEN, "{}", value.len());
    assert_eq!(value.split(',').count(), REGIONS.len());
}

#[test]
fn a_value_past_the_limit_drops_whole_entries() {
    let netcheck = Netcheck { rtt_ms: (0..40).map(|_| ("wnam", u32::MAX)).collect() };
    let value = netcheck.value().unwrap();
    assert!(value.len() <= MAX_VALUE_LEN);
    assert!(value.split(',').all(|e| e == format!("wnam:{}", u32::MAX)));
}

#[test]
fn region_urls_follow_the_signal_scheme() {
    assert_eq!(
        region_url("https://api.example.dev/", "weur").unwrap(),
        "wss://api.example.dev/v1/netcheck/weur"
    );
    assert_eq!(region_url("http://127.0.0.1:8787", "me").unwrap(), "ws://127.0.0.1:8787/v1/netcheck/me");
    assert!(region_url("ftp://x", "me").is_err());
}

fn net(interface: &str, address: &str, prefix: u8) -> LocalNetwork {
    LocalNetwork { interface: interface.into(), address: address.parse().unwrap(), prefix }
}

#[test]
fn the_fingerprint_is_the_subnets_not_the_addresses() {
    let home = fingerprint_of(&[net("en0", "192.168.1.20", 24), net("en0", "2001:db8:1:2::aaaa", 64)]);
    // A new DHCP lease or a rotated IPv6 privacy address on the same network.
    let same = fingerprint_of(&[net("en0", "2001:db8:1:2::bbbb", 64), net("en0", "192.168.1.77", 24)]);
    assert_eq!(home, same);
    // Loopback, link-local and the tailnet do not make another network.
    let with_extras = fingerprint_of(&[
        net("en0", "192.168.1.20", 24),
        net("en0", "2001:db8:1:2::aaaa", 64),
        net("lo0", "127.0.0.1", 8),
        net("en0", "fe80::1", 64),
        net("utun4", "100.70.1.2", 32),
        net("utun4", "fd7a:115c:a1e0::1", 128),
    ]);
    assert_eq!(home, with_extras);
    let cafe = fingerprint_of(&[net("en0", "10.0.0.20", 24)]);
    let cellular = fingerprint_of(&[net("pdp_ip0", "10.0.0.20", 24)]);
    assert_ne!(home, cafe);
    assert_ne!(cafe, cellular);
}

fn key(network: u64) -> CacheKey {
    CacheKey::new("https://api.example.dev/", None, network)
}

fn sample() -> Netcheck {
    Netcheck::from_rtts([("wnam", ms(20)), ("enam", ms(70))])
}

#[test]
fn the_cache_is_keyed_by_service_space_and_network() {
    let now = Instant::now();
    let mut cache = Cache::new(TTL);
    assert!(cache.wants(&key(1), now));
    assert!(cache.begin(&key(1)));
    assert!(!cache.wants(&key(1), now), "one measurement at a time");
    assert!(!cache.begin(&key(1)));
    cache.finish(&key(1), Ok(sample()), now);
    assert_eq!(cache.get(&key(1), now), Some(&sample()));
    assert_eq!(
        CacheKey::new("https://api.example.dev", None, 1),
        key(1),
        "a trailing slash is the same service"
    );
    assert_eq!(cache.get(&key(2), now), None, "another network has its own");
    let dev = BuildSpace::parse("dev:x").unwrap();
    assert_eq!(cache.get(&CacheKey::new("https://api.example.dev", Some(&dev), 1), now), None);
    assert!(!cache.wants(&key(1), now));
    assert!(cache.wants(&key(2), now));
}

#[test]
fn an_entry_expires_after_the_ttl_and_is_measured_again() {
    let start = Instant::now();
    let mut cache = Cache::new(ms(1000));
    cache.begin(&key(1));
    cache.finish(&key(1), Ok(sample()), start);
    assert!(cache.get(&key(1), start + ms(999)).is_some());
    assert!(!cache.wants(&key(1), start + ms(999)));
    assert!(cache.get(&key(1), start + ms(1000)).is_none());
    assert!(cache.wants(&key(1), start + ms(1000)));
    // An expired entry is dropped when another finishes.
    cache.finish(&key(2), Ok(sample()), start + ms(2000));
    assert_eq!(cache.entries.len(), 1);
}

#[test]
fn a_roam_measures_again_but_keeps_the_value_meanwhile() {
    let now = Instant::now();
    let mut cache = Cache::new(TTL);
    cache.finish(&key(1), Ok(sample()), now);
    cache.network_changed();
    assert!(cache.wants(&key(1), now));
    assert_eq!(cache.get(&key(1), now), Some(&sample()));
    cache.begin(&key(1));
    cache.finish(&key(1), Ok(Netcheck::from_rtts([("weur", ms(9))])), now);
    assert!(!cache.wants(&key(1), now));
    assert_eq!(cache.get(&key(1), now).and_then(Netcheck::home), Some("weur"));
}

#[test]
fn a_service_without_netcheck_is_not_asked_again_until_the_ttl() {
    let now = Instant::now();
    let mut cache = Cache::new(TTL);
    cache.begin(&key(1));
    cache.finish(&key(1), Err(NetcheckError::Unsupported(404)), now);
    assert_eq!(cache.get(&key(1), now), None);
    assert!(!cache.wants(&key(1), now));
    assert!(cache.wants(&key(1), now + TTL));
}

#[test]
fn a_failed_measurement_keeps_what_was_there_and_may_run_again() {
    let now = Instant::now();
    let mut cache = Cache::new(TTL);
    cache.finish(&key(1), Ok(sample()), now);
    cache.network_changed();
    cache.begin(&key(1));
    cache.finish(&key(1), Err(NetcheckError::NoAnswer), now);
    assert_eq!(cache.get(&key(1), now), Some(&sample()));
    assert!(cache.wants(&key(1), now));
}

#[test]
fn loopback_services_are_never_measured() {
    assert!(!worth_measuring("http://127.0.0.1:8787"));
    assert!(!worth_measuring("http://localhost:8787/"));
    assert!(!worth_measuring("http://[::1]:8787"));
    assert!(worth_measuring("https://api.cmux.dev"));
    assert!(worth_measuring("https://api.s3.wdev.cmux.dev:443/x"));
    let mut url = "ws://127.0.0.1/v1/teams/t/signal?deviceId=d".to_owned();
    let before = url.clone();
    append_query(&mut url, "http://127.0.0.1", None);
    assert_eq!(url, before);
}

/// A fake Worker: `/v1/netcheck/<region>` answers `ping` with `pong` after
/// `delay(region)`, after an upgrade that itself takes `setup`; unknown
/// regions or `status` get that HTTP status.
#[allow(clippy::result_large_err)] // tungstenite's callback type
async fn fake_worker(
    status: Option<u16>,
    setup: Duration,
    delay: fn(&str) -> Option<Duration>,
) -> (String, Arc<AtomicUsize>) {
    use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let pings = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&pings);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let pings = Arc::clone(&counted);
            tokio::spawn(async move {
                let mut region = String::new();
                let mut authorized = false;
                let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
                    region = request.uri().path().trim_start_matches("/v1/netcheck/").to_owned();
                    authorized = request.headers().get("authorization").is_some_and(|v| v == "Bearer t0k");
                    let refuse = status.or_else(|| (!authorized).then_some(401));
                    match refuse {
                        Some(code) => {
                            let mut refused = ErrorResponse::new(Some("no".into()));
                            *refused.status_mut() =
                                tokio_tungstenite::tungstenite::http::StatusCode::from_u16(code).unwrap();
                            Err(refused)
                        }
                        None => Ok(response),
                    }
                };
                tokio::time::sleep(setup).await;
                let Ok(mut socket) = tokio_tungstenite::accept_hdr_async(stream, callback).await else {
                    return;
                };
                let Some(wait) = delay(&region) else {
                    // A region that never answers.
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    return;
                };
                while let Some(Ok(message)) = socket.next().await {
                    match message {
                        Message::Text(text) if text.as_str() == "ping" => {
                            pings.fetch_add(1, Ordering::Relaxed);
                            tokio::time::sleep(wait).await;
                            if socket.send(Message::Text("pong".into())).await.is_err() {
                                return;
                            }
                        }
                        Message::Close(_) => return,
                        _ => {
                            let _ = socket.close(None).await;
                            return;
                        }
                    }
                }
            });
        }
    });
    (base, pings)
}

#[tokio::test]
async fn measure_pings_every_region_and_picks_home_without_the_upgrade() {
    let (base, pings) = fake_worker(None, ms(150), |region| match region {
        "weur" => Some(ms(5)),
        "afr" => None,
        _ => Some(ms(60)),
    })
    .await;
    let started = Instant::now();
    // The silent region holds it for its whole timeout (1 s); in turn, the eight others alone
    // would take 8 x (150 + 3 x 60) ms = 2.6 s.
    let netcheck = measure(&base, "t0k", None, &crate::egress::Egress::default(), ms(1000)).await.unwrap();
    assert!(
        started.elapsed() < ms(1800),
        "regions run in parallel, the silent one bounded: {:?}",
        started.elapsed()
    );
    assert_eq!(netcheck.home(), Some("weur"));
    let regions: Vec<_> = netcheck.rtt_ms.iter().map(|(r, _)| *r).collect();
    assert_eq!(regions, ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "me"], "afr never answered");
    let weur = netcheck.rtt_ms.iter().find(|(r, _)| *r == "weur").unwrap().1;
    assert!(weur < 100, "the 150 ms upgrade is not counted: {weur}");
    // Three pings to each of the eight answering regions.
    assert_eq!(pings.load(Ordering::Relaxed), 8 * PINGS);
    assert!(netcheck.value().unwrap().contains("weur:"));
}

#[tokio::test]
async fn an_older_worker_without_netcheck_is_unsupported() {
    let (base, _) = fake_worker(Some(404), Duration::ZERO, |_| Some(ms(1))).await;
    assert_eq!(
        measure(&base, "t0k", None, &crate::egress::Egress::default(), ms(1000)).await,
        Err(NetcheckError::Unsupported(404))
    );
    let (base, _) = fake_worker(Some(503), Duration::ZERO, |_| Some(ms(1))).await;
    assert_eq!(
        measure(&base, "t0k", None, &crate::egress::Egress::default(), ms(1000)).await,
        Err(NetcheckError::Unsupported(503))
    );
}

#[tokio::test]
async fn a_wrong_token_or_no_server_is_no_answer() {
    let (base, _) = fake_worker(None, Duration::ZERO, |_| Some(ms(1))).await;
    assert_eq!(
        measure(&base, "wrong", None, &crate::egress::Egress::default(), ms(1000)).await,
        Err(NetcheckError::NoAnswer)
    );
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let closed = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    assert_eq!(
        measure(&closed, "t0k", None, &crate::egress::Egress::default(), ms(1000)).await,
        Err(NetcheckError::NoAnswer)
    );
}

/// Off by default: a cached measurement reaches no URL until the switch is
/// on, and `with_value` adds nothing for no value.
#[test]
fn the_switch_is_off_by_default_and_gates_the_wire() {
    assert_eq!(SWITCH_ENV, "CMUX_MOBILE_NETCHECK");
    if std::env::var(SWITCH_ENV).is_err() {
        assert!(!enabled());
    }
    let base = "https://netcheck-switch.example";
    let key = CacheKey::new(base, None, network_fingerprint());
    {
        let mut cache = cache();
        cache.begin(&key);
        cache.finish(&key, Ok(sample()), Instant::now());
    }
    set_enabled(Some(false));
    assert_eq!(cached_value(base, None), None);
    set_enabled(Some(true));
    assert_eq!(cached_value(base, None), sample().value());
    set_enabled(None);

    let mut url = "wss://h/v1/relay/s?deviceId=d".to_owned();
    with_value(&mut url, None);
    with_value(&mut url, Some(""));
    assert_eq!(url, "wss://h/v1/relay/s?deviceId=d");
    with_value(&mut url, Some("wnam:31,enam:72"));
    assert_eq!(url, "wss://h/v1/relay/s?deviceId=d&netcheck=wnam:31,enam:72");
}
