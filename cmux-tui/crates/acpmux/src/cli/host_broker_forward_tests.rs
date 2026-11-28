//! Several owners: a stand-in daemon answers `remote.pipe` per owner as a good broker, one that
//! refuses the pipe, or one whose link is up but whose broker never answers (the stall the
//! progress check is for).

use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

#[derive(Clone, Copy)]
enum Broker {
    /// Answers a ping `ok`, and any other line `broker:<line>`.
    Good,
    /// The daemon refuses the pipe (the owner is not reachable).
    Refused,
    /// The pipe opens; the broker never answers.
    Stalled,
}

/// A daemon socket in `dir` whose `remote.pipe` to owner `name` behaves as `brokers` says.
fn daemon(dir: &Path, brokers: Vec<(&'static str, Broker)>) -> PathBuf {
    let path = dir.join("daemon.sock");
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((conn, _)) = listener.accept().await else { return };
            let brokers = brokers.clone();
            tokio::spawn(async move {
                let mut conn = BufReader::new(conn);
                let mut line = String::new();
                if conn.read_line(&mut line).await.unwrap_or(0) == 0 {
                    return;
                }
                let req: Value = serde_json::from_str(&line).unwrap();
                let owner = req["params"]["machine"].as_str().unwrap_or("").to_owned();
                let kind = brokers.iter().find(|(n, _)| *n == owner).map(|(_, k)| *k);
                match kind {
                    None | Some(Broker::Refused) => {
                        let reply = json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -32000,
                            "message": "not connected", "data": {"reason": "peer_unreachable"}}});
                        let _ = conn.get_mut().write_all(format!("{reply}\n").as_bytes()).await;
                    }
                    Some(kind) => {
                        let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {}});
                        let _ = conn.get_mut().write_all(format!("{reply}\n").as_bytes()).await;
                        loop {
                            let mut line = String::new();
                            if conn.read_line(&mut line).await.unwrap_or(0) == 0 {
                                return;
                            }
                            if matches!(kind, Broker::Stalled) {
                                continue;
                            }
                            let answer = if line.contains("\"ping\"") {
                                format!("{{\"ok\":true,\"host\":\"{owner}\"}}\n")
                            } else {
                                format!("{owner}:{line}")
                            };
                            let _ = conn.get_mut().write_all(answer.as_bytes()).await;
                        }
                    }
                }
            });
        }
    });
    path
}

fn names(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn a_connection_tries_healthy_then_unchecked_then_down_owners_each_in_the_given_order() {
    let owners = Owners::new(&names(&["cp-1", "cp-2", "huge-blue", "cosmic-gray", "cp-1"]), None);
    assert_eq!(owners.order(), names(&["cp-1", "cp-2", "huge-blue", "cosmic-gray"]), "no repeat");
    owners.note("cp-1", Err("stalled".into()));
    owners.note("huge-blue", Ok(Duration::from_millis(200)));
    owners.note("cosmic-gray", Ok(Duration::from_millis(900)));
    assert_eq!(owners.order(), names(&["huge-blue", "cosmic-gray", "cp-2", "cp-1"]));
    owners.note("cp-1", Ok(Duration::from_millis(220)));
    assert_eq!(owners.order()[0], "cp-1", "a recovered first choice is first again");
}

#[tokio::test]
async fn the_progress_check_counts_a_stalled_broker_behind_an_open_link_as_down() {
    let dir = tempfile::tempdir().unwrap();
    let sock = daemon(
        dir.path(),
        vec![("good", Broker::Good), ("refused", Broker::Refused), ("stalled", Broker::Stalled)],
    );
    assert!(check("good", &sock).await.is_ok());
    let refused = check("refused", &sock).await.unwrap_err();
    assert!(refused.contains("peer_unreachable"), "{refused}");
    let started = Instant::now();
    let stalled = check("stalled", &sock).await.unwrap_err();
    assert!(stalled.contains("no ping answer"), "{stalled}");
    assert!(started.elapsed() < HEALTH_BOUND + Duration::from_secs(2), "bounded");
}

#[tokio::test]
async fn a_call_fails_over_past_owners_that_are_down_and_the_records_say_why() {
    let dir = tempfile::tempdir().unwrap();
    let sock = daemon(
        dir.path(),
        vec![("cp-1", Broker::Stalled), ("cp-2", Broker::Refused), ("huge-blue", Broker::Good)],
    );
    let file = dir.path().join("broker-owners").join("carrier.sock.json");
    let owners = Arc::new(Owners::new(&names(&["cp-1", "cp-2", "huge-blue"]), Some(file.clone())));
    check_all(&owners, &sock).await;
    assert_eq!(owners.order(), names(&["huge-blue", "cp-1", "cp-2"]));

    // A lane-gh call through the forward's socket lands on the healthy owner.
    let listen = dir.path().join("carrier.sock");
    let listener = UnixListener::bind(&listen).unwrap();
    let (owners2, sock2) = (owners.clone(), sock.clone());
    tokio::spawn(async move {
        let (conn, _) = listener.accept().await.unwrap();
        carry_any(conn, &owners2, &sock2).await.unwrap();
    });
    let mut client = BufReader::new(UnixStream::connect(&listen).await.unwrap());
    client.get_mut().write_all(b"{\"op\":\"call\",\"tool\":\"get\"}\n").await.unwrap();
    let mut back = String::new();
    client.read_line(&mut back).await.unwrap();
    assert_eq!(back, "huge-blue:{\"op\":\"call\",\"tool\":\"get\"}\n");

    // The records are on disk beside the peer state, and seed the next run's verdicts.
    let saved: Vec<OwnerRecord> = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    let cp1 = saved.iter().find(|r| r.owner == "cp-1").unwrap();
    assert_eq!(cp1.healthy, Some(false));
    assert!(cp1.error.as_deref().unwrap_or("").contains("no ping answer"));
    let again = Owners::new(&names(&["cp-1", "cp-2", "huge-blue"]), Some(file));
    assert_eq!(again.order()[0], "huge-blue");
    assert_eq!(owners.records().iter().find(|r| r.owner == "huge-blue").unwrap().carried, 1);
}

#[tokio::test]
async fn an_owner_whose_pipe_will_not_open_is_passed_over_in_the_same_call() {
    let dir = tempfile::tempdir().unwrap();
    let sock = daemon(dir.path(), vec![("cp-1", Broker::Refused), ("cp-2", Broker::Good)]);
    // No check ran: both unchecked, so cp-1 is tried first and refuses.
    let owners = Arc::new(Owners::new(&names(&["cp-1", "cp-2"]), None));
    let listen = dir.path().join("f.sock");
    let listener = UnixListener::bind(&listen).unwrap();
    let (o, s) = (owners.clone(), sock.clone());
    tokio::spawn(async move {
        let (conn, _) = listener.accept().await.unwrap();
        carry_any(conn, &o, &s).await.unwrap();
    });
    let mut client = BufReader::new(UnixStream::connect(&listen).await.unwrap());
    client.get_mut().write_all(b"x\n").await.unwrap();
    let mut back = String::new();
    client.read_line(&mut back).await.unwrap();
    assert_eq!(back, "cp-2:x\n");
    assert_eq!(owners.order(), names(&["cp-2", "cp-1"]), "cp-1 marked down by the open");
}

#[tokio::test]
async fn with_every_owner_down_nothing_is_sent_and_the_call_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let sock = daemon(dir.path(), vec![("cp-1", Broker::Refused)]);
    let owners = Owners::new(&names(&["cp-1", "cp-2"]), None);
    let (a, _b) = UnixStream::pair().unwrap();
    let err = carry_any(a, &owners, &sock).await.unwrap_err().to_string();
    assert!(err.contains("no owner's broker reachable"), "{err}");
    assert!(owners.records().iter().all(|r| r.healthy == Some(false)));
}

// RFD 0060 Weft move 3: a session is pointed at the daemon-held forward only while an owner's
// broker answered its last check, so a forward with no broker behind it never takes a session off
// the ssh socket.
#[tokio::test]
async fn the_held_socket_is_offered_only_while_an_owner_is_healthy() {
    let dir = tempfile::tempdir().unwrap();
    let listen = dir.path().join("carrier.sock");
    let down = daemon(dir.path(), vec![("cp-1", Broker::Stalled), ("cp-2", Broker::Refused)]);
    let owners = Owners::new(&names(&["cp-1", "cp-2"]), None);
    assert_eq!(healthy_socket(&listen, &owners), None, "unchecked owners are not healthy");
    check_all(&owners, &down).await;
    assert_eq!(healthy_socket(&listen, &owners), None, "every owner down");

    owners.note("cp-2", Ok(Duration::from_millis(200)));
    assert_eq!(healthy_socket(&listen, &owners), Some(listen.clone()));
    owners.note("cp-2", Err("no ping answer within 5 s".into()));
    assert_eq!(healthy_socket(&listen, &owners), None, "the last check decides");
}

#[test]
fn the_held_socket_sits_beside_lane_ghs_default() {
    let held = held_socket_path();
    assert!(held.ends_with(".cache/lane-gh/carrier.sock"), "{}", held.display());
}

#[test]
fn lane_gh_carrier_takes_machine_names_or_none() {
    use crate::config::Config;
    let mut config = Config::default();
    config.set("lane_gh_carrier", "huge-blue, cosmic-gray,huge-blue").unwrap();
    assert_eq!(config.lane_gh_carrier, Some(names(&["huge-blue", "cosmic-gray"])));
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["laneGhCarrier"], json!(["huge-blue", "cosmic-gray"]));
    for bad in ["/tmp/x.sock", "--socket", "a;b"] {
        assert!(config.set("lane_gh_carrier", bad).is_err(), "{bad}");
    }
    assert_eq!(config.lane_gh_carrier, Some(names(&["huge-blue", "cosmic-gray"])), "kept");
    config.set("lane-gh-carrier", "none").unwrap();
    assert_eq!(config.lane_gh_carrier, None);
    assert!(
        serde_json::to_value(&config).unwrap().get("laneGhCarrier").is_none(),
        "off by default"
    );
}
