use super::*;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::TcpListener;

const MACHINE: &str = "vm_0123456789abcdefghij";

#[test]
fn only_a_platform_machine_id_reaches_the_url() {
    assert!(valid_machine(MACHINE));
    for bad in [
        "vm_0123456789ABCDEFGHIJ",
        "vm_0123456789abcdefghi",
        "vm_0123456789abcdefghijk",
        "vm_../../../v1/teams/xx",
        "machine_0123456789abcd",
        "",
    ] {
        assert!(!valid_machine(bad), "{bad}");
    }
}

#[test]
fn a_platform_needs_https_a_machine_and_a_well_formed_team() {
    let new = |base: &str, team: Option<&str>, machine: &str| {
        Platform::new(base, team.map(str::to_owned), machine, "token".into()).map(|_| ())
    };
    assert!(new("https://cloud-api.cmux.dev", Some("team_abc123"), MACHINE).is_ok());
    assert!(new("https://cloud-api.cmux.dev", None, MACHINE).is_ok());
    assert!(new("https://cloud-api.cmux.dev", Some(""), MACHINE).is_ok());
    assert!(new("http://127.0.0.1:8787", None, MACHINE).is_ok());
    assert!(new("http://cloud-api.cmux.dev", None, MACHINE).is_err());
    assert!(new("https://cloud-api.cmux.dev", Some("abc"), MACHINE).is_err());
    assert!(new("https://cloud-api.cmux.dev", Some("team_a\r\nx: y"), MACHINE).is_err());
    assert!(new("https://cloud-api.cmux.dev", None, "vm_x").is_err());
}

#[test]
fn the_carrier_url_is_the_machine_route_under_the_base() {
    let platform = Platform::new("https://cloud-api.cmux.dev", None, MACHINE, "t".into()).unwrap();
    assert_eq!(
        platform.url().unwrap().as_str(),
        "https://cloud-api.cmux.dev/v1/cloud/machines/vm_0123456789abcdefghij/carrier"
    );
}

#[test]
fn a_refusal_keeps_its_code_and_whether_it_may_pass_later() {
    let paused = json!({"ok": false, "error": {"code": "cloud.machine.paused", "message": "paused"}});
    match read_answer(409, &paused) {
        Err(CarrierError::Refused { code, retryable: false, .. }) => {
            assert_eq!(code, "cloud.machine.paused");
        }
        other => panic!("{other:?}"),
    }
    let unreachable = json!({"ok": false, "error": {"code": "owner.unreachable"}});
    assert!(read_answer(503, &unreachable).unwrap_err().retryable());
    let malformed = json!({"ok": true, "value": {"relay": "wss://x"}});
    assert!(matches!(read_answer(200, &malformed), Err(CarrierError::Answer(_))));
}

#[test]
fn a_grant_refusal_or_a_wrong_daemon_is_never_retried() {
    assert!(!CarrierError::Handshake("x".into()).retryable());
    assert!(!CarrierError::Unauthorized.retryable());
    assert!(CarrierError::transport("relay", "reset").retryable());
}

#[test]
fn a_new_private_key_is_32_random_bytes() {
    let first = generate_private_key().unwrap();
    let second = generate_private_key().unwrap();
    assert_ne!(*first, *second);
    assert_ne!(*first, [0; 32]);
}

/// One HTTP/1.1 exchange on a local listener: the request's head and body,
/// answered with `status` and `body`.
async fn serve_once(status: u16, body: Value) -> (String, tokio::task::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = tokio::io::split(stream);
        let mut reader = BufReader::new(read);
        let mut head = String::new();
        let mut length = 0;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap();
            }
            if line == "\r\n" {
                break;
            }
            head.push_str(&line);
        }
        let mut request = vec![0; length];
        reader.read_exact(&mut request).await.unwrap();
        let reply = body.to_string();
        let answer = format!(
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
            reply.len()
        );
        write.write_all(answer.as_bytes()).await.unwrap();
        format!("{head}\n{}", String::from_utf8(request).unwrap())
    });
    (base, task)
}

fn answer() -> Value {
    json!({
        "relay": "relay+do://relay.cmux.dev",
        "slot": "slot_1",
        "ticket": "tkt.1",
        "expires_at": now_secs() + 600,
        "grant": "h.c.s",
        "daemon_key": carrier_answer::key_text(&[9; 32]),
    })
}

#[tokio::test]
async fn an_ask_names_the_phone_key_its_token_and_its_team() {
    let (base, server) = serve_once(200, json!({"ok": true, "value": answer()})).await;
    let platform =
        Platform::with_tokens(&base, Some("team_abc".into()), MACHINE, Arc::new(Rotating::default()))
            .unwrap();
    let parsed = platform.fetch(Some(&[5; 32])).await.unwrap();
    assert_eq!(parsed.daemon_key, Some([9; 32]));
    let request = server.await.unwrap();
    let lower = request.to_ascii_lowercase();
    assert!(request.starts_with(&format!("POST /v1/cloud/machines/{MACHINE}/carrier ")), "{request}");
    assert!(lower.contains("authorization: bearer access-1"), "the source's current token: {request}");
    assert!(lower.contains("x-cmux-team: team_abc"), "{request}");
    assert!(request.ends_with(&json!({"noise_key": carrier_answer::key_text(&[5; 32])}).to_string()));
}

#[tokio::test]
async fn a_ticket_only_ask_sends_an_empty_body_and_no_team_when_none() {
    let (base, server) = serve_once(200, json!({"ok": true, "value": answer()})).await;
    let platform = Platform::new(&base, None, MACHINE, "access".into()).unwrap();
    platform.fetch(None).await.unwrap();
    let request = server.await.unwrap();
    assert!(request.ends_with("\n{}"), "{request}");
    assert!(!request.to_ascii_lowercase().contains("x-cmux-team"), "{request}");
}

#[tokio::test]
async fn a_fresh_ticket_is_reused_and_a_stale_one_is_asked_again() {
    let platform = Arc::new(Platform::new("https://cloud-api.cmux.dev", None, MACHINE, "t".into()).unwrap());
    let fresh = carrier_answer::parse_relay(&answer()).unwrap();
    let tickets = Tickets::new(platform, &fresh);
    assert_eq!(tickets.ticket().await.unwrap(), "tkt.1");

    let (base, server) = serve_once(200, json!({"ok": true, "value": answer()})).await;
    let platform = Arc::new(Platform::new(&base, None, MACHINE, "t".into()).unwrap());
    let mut stale = answer();
    stale["ticket"] = json!("tkt.old");
    stale["expires_at"] = json!(now_secs() + 5);
    let tickets = Tickets::new(platform, &carrier_answer::parse_relay(&stale).unwrap());
    assert_eq!(tickets.ticket().await.unwrap(), "tkt.1", "a ticket inside the margin is replaced");
    assert!(server.await.unwrap().ends_with("\n{}"), "a ticket-only ask");
}

/// A platform that names no daemon key yet: the dial asks again while its
/// deadline lasts, then ends with the refusal the app stops dialing on.
#[tokio::test]
async fn no_daemon_key_is_asked_again_then_refused_with_its_code() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let asks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let grants = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = asks.clone();
    let granted = grants.clone();
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let (read, mut write) = tokio::io::split(stream);
            let mut reader = BufReader::new(read);
            let mut length = 0;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
            }
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body).await;
            if String::from_utf8_lossy(&body).contains("noise_key") {
                granted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
            let mut value = answer();
            value.as_object_mut().unwrap().remove("daemon_key");
            let reply = json!({"ok": true, "value": value}).to_string();
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                reply.len()
            );
            let _ = write.write_all(head.as_bytes()).await;
            let _ = write.write_all(reply.as_bytes()).await;
        }
    });
    let platform = Arc::new(Platform::new(&base, None, MACHINE, "token".into()).unwrap());
    let identity = StaticIdentity::from_private([3; 32]);
    let deadline = Instant::now() + Duration::from_millis(1_500);
    let error = CarrierSession::dial(platform, identity, "iPhone".into(), deadline).await.err().unwrap();
    match error {
        CarrierError::Refused { code, .. } => assert_eq!(code, NO_DAEMON_KEY),
        other => panic!("{other:?}"),
    }
    assert!(asks.load(std::sync::atomic::Ordering::SeqCst) >= 2, "asked again inside the dial");
    // Only the first ask names the phone's key (mints a grant); the waits after it are ticket-only.
    assert_eq!(grants.load(std::sync::atomic::Ordering::SeqCst), 1, "one grant while the key is missing");
    server.abort();
}

/// A token source whose token changes at each forced refresh.
#[derive(Default)]
struct Rotating {
    refreshes: std::sync::atomic::AtomicUsize,
}

#[async_trait::async_trait]
impl TokenSource for Rotating {
    async fn access_token(&self, force_refresh: bool) -> Result<Zeroizing<String>, CarrierError> {
        if force_refresh {
            self.refreshes.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        let n = self.refreshes.load(std::sync::atomic::Ordering::SeqCst) + 1;
        Ok(Zeroizing::new(format!("access-{n}")))
    }
}

/// Answers each of `replies` in turn (status, body), one per connection,
/// and hands back each request's head.
async fn serve_each(replies: Vec<(u16, Value)>) -> (String, tokio::task::JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let mut heads = Vec::new();
        for (status, body) in replies {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = tokio::io::split(stream);
            let mut reader = BufReader::new(read);
            let mut head = String::new();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).await.unwrap();
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
                head.push_str(&line);
            }
            let mut request = vec![0; length];
            reader.read_exact(&mut request).await.unwrap();
            let reply = body.to_string();
            let answer = format!(
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                reply.len()
            );
            write.write_all(answer.as_bytes()).await.unwrap();
            heads.push(head);
        }
        heads
    });
    (base, task)
}

#[tokio::test]
async fn a_refused_token_is_refreshed_once_and_the_ask_made_again() {
    let refused = json!({"ok": false, "error": {"code": "auth.unauthenticated"}});
    let (base, server) =
        serve_each(vec![(401, refused), (200, json!({"ok": true, "value": answer()}))]).await;
    let tokens = Arc::new(Rotating::default());
    let platform = Platform::with_tokens(&base, None, MACHINE, tokens.clone()).unwrap();
    platform.fetch(None).await.expect("the second ask passes");
    let heads = server.await.unwrap();
    assert!(heads[0].to_ascii_lowercase().contains("bearer access-1"), "{}", heads[0]);
    assert!(heads[1].to_ascii_lowercase().contains("bearer access-2"), "the refreshed token: {}", heads[1]);
    assert_eq!(tokens.refreshes.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_token_refused_twice_is_unauthorized() {
    let refused = json!({"ok": false, "error": {"code": "auth.unauthenticated"}});
    let (base, server) = serve_each(vec![(401, refused.clone()), (401, refused)]).await;
    let platform = Platform::with_tokens(&base, None, MACHINE, Arc::new(Rotating::default())).unwrap();
    assert_eq!(platform.fetch(None).await.unwrap_err(), CarrierError::Unauthorized);
    assert_eq!(server.await.unwrap().len(), 2);
}

#[test]
fn an_unusable_answer_is_retryable() {
    let malformed = json!({"ok": true, "value": {"relay": "wss://x"}});
    let error = read_answer(200, &malformed).unwrap_err();
    assert!(matches!(error, CarrierError::Answer(_)), "{error:?}");
    assert!(error.retryable());
}

#[test]
fn a_wrong_daemon_or_a_refused_grant_is_a_handshake_failure_never_retried() {
    use cmux_remote::connection::ConnectionError;
    use cmux_remote::crypto::CryptoError;
    let wrong_key = connection_error(&ConnectionError::Crypto(CryptoError::DaemonKeyMismatch {
        expected: "aa".into(),
        actual: "bb".into(),
    }));
    assert!(matches!(wrong_key, CarrierError::Handshake(_)), "{wrong_key:?}");
    assert!(!wrong_key.retryable());
    let refused = connection_error(&ConnectionError::Crypto(CryptoError::Unauthorized("grant".into())));
    assert!(matches!(refused, CarrierError::Handshake(_)), "{refused:?}");
    assert!(!refused.retryable());
    // A session the daemon lost is asked again with a fresh session.
    assert!(connection_error(&ConnectionError::SessionUnavailable).retryable());
}

#[test]
fn the_watchers_backstop_spares_a_recovery_and_ends_one_that_gave_up() {
    use cmux_remote::observability::ConnectionState::{Connected, Disconnected, Reconnecting};
    let t0 = Instant::now();
    // A burst parks (Disconnected) for 5 s, redials (Reconnecting), and comes back: never ended.
    let (since, end) = backstop(Disconnected, None, t0);
    assert_eq!(since, Some(t0));
    assert!(end.unwrap() > t0 + Duration::from_secs(5), "a 5 s park is spared");
    let (since, end) = backstop(Disconnected, since, t0 + Duration::from_secs(5));
    assert_eq!(since, Some(t0), "the same Disconnected run keeps its start");
    assert!(end.unwrap() > t0 + Duration::from_secs(5));
    assert_eq!(
        backstop(Reconnecting, since, t0 + Duration::from_secs(5)),
        (None, None),
        "a redial resets it"
    );
    assert_eq!(backstop(Connected, since, t0 + Duration::from_secs(6)), (None, None));
    // Disconnected and nothing more for longer than any recovery runs: ended at that point.
    let (_, end) = backstop(Disconnected, None, t0);
    assert_eq!(end, Some(t0 + RESUME_DEADLINE + GAVE_UP_MARGIN));
}

/// The key is stored a moment after the first ask (the machine just bound): the dial waits for it
/// with ticket-only asks, then asks for a grant again, once, and goes on to the relay. Two grants
/// in all, never one per wait. The relay here is a local address nothing answers, so the dial ends
/// at the relay step; what counts is that the wait ended and how many grants it cost.
#[tokio::test]
async fn a_key_stored_during_the_wait_ends_it_with_one_more_grant() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let grants = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let tickets = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let (granted, ticketed) = (grants.clone(), tickets.clone());
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let (read, mut write) = tokio::io::split(stream);
            let mut reader = BufReader::new(read);
            let mut length = 0;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
            }
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body).await;
            let grant_ask = String::from_utf8_lossy(&body).contains("noise_key");
            if grant_ask {
                granted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            } else {
                ticketed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
            // Bound after the second ticket-only ask: from then on every answer has the key.
            let bound = ticketed.load(std::sync::atomic::Ordering::SeqCst) >= 2;
            let mut value = answer();
            value["relay"] = json!("relay+ws://127.0.0.1:9");
            if !bound {
                value.as_object_mut().unwrap().remove("daemon_key");
            }
            let reply = json!({"ok": true, "value": value}).to_string();
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                reply.len()
            );
            let _ = write.write_all(head.as_bytes()).await;
            let _ = write.write_all(reply.as_bytes()).await;
        }
    });
    let platform = Arc::new(Platform::new(&base, None, MACHINE, "token".into()).unwrap());
    let identity = StaticIdentity::from_private([3; 32]);
    // Long enough for two waits and the second grant ask, short enough that the unanswered relay
    // ends the dial quickly.
    let deadline = Instant::now() + Duration::from_millis(2_500);
    let error = CarrierSession::dial(platform, identity, "iPhone".into(), deadline).await.err().unwrap();
    assert!(
        !matches!(&error, CarrierError::Refused { code, .. } if code == NO_DAEMON_KEY),
        "the wait ended once the key was stored: {error:?}"
    );
    assert!(tickets.load(std::sync::atomic::Ordering::SeqCst) >= 2, "it waited with ticket-only asks");
    assert!(grants.load(std::sync::atomic::Ordering::SeqCst) >= 2, "a grant again once the key was there");
    server.abort();
}
