//! Row 7b part one's callers on a daemon in this process, served on a unix socket as the daemon
//! serves it (v1 and the v2 list on one socket, the list tee filling the index): each form
//! prints the same bytes read through the v2 list as through v1; a daemon without v2, or with
//! v2 and `list` off, gives each caller its v1 path; `--limit` and `--cursor` agree; and the
//! gates `v2_pr07b_*`.

use super::ls::LsArgs;
use crate::cli::list_read::Via;
use crate::client::Client;
use crate::hub::Hub;
use acpmux_book::index::SummaryIndex;
use acpmux_core::life::V2;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// What the v2 side of a daemon serves.
#[derive(Clone, Copy, PartialEq)]
enum Serves {
    /// No v2 handle: the upgrade is not a method.
    NoV2,
    /// v2 with no surface: the upgrade names `list`, and is refused.
    ListOff,
    /// v2 with `list`.
    List,
}

/// A daemon in this process on a unix socket, and a v1 client connected to it.
struct Daemon {
    _hub: Arc<Hub>,
    v2: Option<Arc<V2>>,
    path: PathBuf,
    client: Arc<Client>,
    _dir: tempfile::TempDir,
}

fn memory_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

/// A session's record: `status`, updated at `at`, with `tags` (`{key: value}`).
fn meta(id: &str, name: &str, status: &str, at: u64, tags: Value) -> crate::store::SessionMeta {
    let tags: serde_json::Map<String, Value> = tags
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, value)| (key.clone(), json!({"value": value})))
        .collect();
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "title": format!("{name}'s title"),
        "harness": "claude", "cwd": "/work", "status": status, "createdAt": at - 1_000,
        "updatedAt": at, "turnCount": 3, "nameGiven": true, "tags": tags,
    }))
    .unwrap()
}

/// Serves a new hub on a new socket, `seed` giving it its rows (and their count). With the v2
/// list, the tee is started first and fills its index from the hub, and this waits until it
/// holds that many rows.
async fn serve(serves: Serves, seed: impl FnOnce(&Hub) -> usize) -> Daemon {
    let hub = memory_hub();
    let v2 = match serves {
        Serves::NoV2 => None,
        Serves::ListOff | Serves::List => {
            let (index, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
            let surfaces = if serves == Serves::List {
                ["list".to_owned()].into_iter().collect()
            } else {
                Default::default()
            };
            let v2 = Arc::new(V2::with_surfaces(index, writer, surfaces));
            let (tee, task) = crate::hub::list_tee::start_v2_tee(hub.clone(), v2.clone());
            hub.install_v2_tee(tee);
            v2.hub.set_page_provider(Arc::new(crate::hub::list_tee::V1PageProvider::new(
                hub.clone(),
            )));
            tokio::spawn(task);
            tokio::spawn(v2.take_writer().unwrap().run());
            Some(v2)
        }
    };
    let rows = seed(&hub);
    if let Some(v2) = &v2 {
        let deadline = Instant::now() + Duration::from_secs(60);
        while v2.hub.snapshot().len() < rows {
            let held: Vec<String> =
                v2.hub.snapshot().iter().map(|row| row.key().chat_id.to_string()).collect();
            assert!(Instant::now() < deadline, "the tee holds {} of {rows} rows: {held:?}", held.len());
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("acpmux.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix_with_v2(hub.clone(), listener, v2.clone()));
    let client = Client::connect(&path).await.unwrap();
    Daemon { _hub: hub, v2, path, client, _dir: dir }
}

/// The differential fixture: live and closed chats, a child whose parent is closed, a child whose
/// parent is archived, tags, and a peer whose link is down (its rows stale), with one live and
/// one closed row. No closed chat holds a message (decision 209). The rows the v2 index holds.
fn fixture(hub: &Hub) -> usize {
    fixture_with(hub, true)
}

/// [`fixture`], its peer listing a closed row when `peer_closed`, else only its live one.
fn fixture_with(hub: &Hub, peer_closed: bool) -> usize {
    let now = crate::store::now_ms();
    let at = |n: u64| now - 600_000 + n * 1_000;
    let mut rows = 0;
    let mut add = |meta| {
        hub.insert_test_session(meta);
        rows += 1;
    };
    add(meta("c-closed-parent", "closed-parent", "closed", at(1), json!({})));
    add(meta("c-archived-parent", "archived-parent", "idle", at(2), json!({"archived": "1"})));
    add(meta("c-under-closed", "under-closed", "idle", at(3), json!({"spawnedBy": "c-closed-parent"})));
    add(meta("c-under-archived", "under-archived", "idle", at(4), json!({"spawnedBy": "c-archived-parent"})));
    for n in 0..6 {
        let tags = if n % 2 == 0 { json!({"area": "acpmux"}) } else { json!({}) };
        add(meta(&format!("c-live-{n}"), &format!("chat-{n}"), "idle", at(10 + n), tags));
    }
    for n in 0..5 {
        add(meta(&format!("c-old-{n}"), &format!("old-{n}"), "closed", at(30 + n), json!({"area": "acpmux"})));
    }
    // A running chat that is stuck: its summary's `state` reads `stuck`, its row's `status`
    // `running`, and `--status running` lists it as v1 does.
    let mut stuck = meta("c-stuck", "stuck-run", "running", at(20), json!({}));
    stuck.harness_failures = serde_json::from_value(json!({"throughSeq": 9, "attempts": 3,
        "since": at(19), "reason": "auth", "error": "401 unauthorized"}))
    .unwrap();
    add(stuck);
    let mut peer_rows = vec![json!({"sessionId": "p-live", "qualifiedSessionId": "far/p-live",
        "name": "far/lane", "status": "idle", "updatedAt": at(40),
        "tags": {"area": {"value": "acpmux"}}})];
    if peer_closed {
        peer_rows.push(json!({"sessionId": "p-closed", "qualifiedSessionId": "far/p-closed",
            "name": "far/done", "status": "closed", "updatedAt": at(5)}));
    }
    hub.seed_down_peer("far", peer_rows);
    // The v2 index keeps a peer's live rows only (`SummaryIndex::apply_summary`).
    rows + 1
}

#[derive(clap::Parser)]
struct Argv {
    #[command(flatten)]
    ls: LsArgs,
}

fn ls_args(argv: &[&str]) -> LsArgs {
    use clap::Parser as _;
    Argv::try_parse_from(std::iter::once("ls").chain(argv.iter().copied())).unwrap().ls
}

/// What `acpmux ls ARGV` prints from `daemon`, `via` the v2 list (its path) or v1.
async fn ls(daemon: &Daemon, argv: &[&str], v2: bool, now: u64) -> String {
    let json_out = argv.contains(&"--json");
    let argv: Vec<&str> = argv.iter().copied().filter(|a| *a != "--json").collect();
    let via = if v2 { Via::List(daemon.path.clone()) } else { Via::V1 };
    super::ls::output(ls_args(&argv), json_out, &daemon.client, via, now).await.unwrap()
}

/// Each caller's output from `daemon`, `via` the v2 list or v1, by name.
async fn callers(daemon: &Daemon, v2: bool) -> Vec<(&'static str, String)> {
    let via = || if v2 { Via::List(daemon.path.clone()) } else { Via::V1 };
    let now = 1_800_000_000_000;
    let client = &daemon.client;
    let targets = super::fanout::targets_via(client, via(), "area=acpmux", None).await.unwrap();
    vec![
        ("ls", ls(daemon, &[], v2, now).await),
        ("ls --json", ls(daemon, &["--json"], v2, now).await),
        ("pending", super::standard::pending_output(client, via(), false).await.unwrap()),
        ("pending --json", super::standard::pending_output(client, via(), true).await.unwrap()),
        ("send --tag --dry-run", format!("{targets:?}")),
        ("mcp ls", crate::acpmux_mcp::ls_via(client, &json!({}), via()).await.to_string()),
        (
            "mcp ls closed",
            crate::acpmux_mcp::ls_via(client, &json!({"status": "closed"}), via()).await.to_string(),
        ),
    ]
}

/// Every form of the four callers prints the same bytes read through the v2 list as through
/// v1, on one daemon whose peer lists a closed row (the forms that walk the whole view read v1,
/// decision 213) and on one whose peer does not (they walk v2): the recorded run prints each
/// pair.
#[tokio::test]
async fn every_form_prints_the_same_bytes_on_v2_as_on_v1() {
    for peer_closed in [false, true] {
        eprintln!("=== the peer lists a closed row: {peer_closed} ===");
        every_form_on(serve(Serves::List, |hub| fixture_with(hub, peer_closed)).await, peer_closed)
            .await;
    }
}

async fn every_form_on(daemon: Daemon, peer_closed: bool) {
    // The live rows: ten here and the peer's one.
    let live_text = 11.to_string();
    let now = crate::store::now_ms();
    let forms: Vec<Vec<&str>> = vec![
        vec![],
        vec!["-a"],
        vec!["-w"],
        vec!["--live"],
        vec!["--leads"],
        vec!["--pending"],
        vec!["--status", "idle"],
        vec!["--status", "running"],
        vec!["--status", "closed"],
        vec!["--status", "stuck"],
        vec!["--status", "waiting"],
        vec!["--json"],
        vec!["--json", "--live"],
        vec!["--json", "--with-tools", "--live"],
        vec!["--fields", "name,status,peer,spawnedBy,stale"],
        vec!["--tag", "area=acpmux"],
        vec!["--since", "5m"],
        vec!["chat-*"],
        vec!["local/c-live-0", "--json"],
        vec!["far/*", "--json"],
        vec!["--machine", "far", "--json"],
        vec!["--machine", "local"],
        vec!["--json", "--limit", "2"],
        vec!["--json", "--status", "closed", "--limit", "1"],
        vec!["--json", "--tag", "area=acpmux", "--limit", "3"],
        // A list that ends exactly at N, and one that goes on.
        vec!["--json", "--live", "--limit", &live_text],
        vec!["--json", "--live", "--limit", "1"],
    ];
    let mut differ = Vec::new();
    for form in &forms {
        let v1 = ls(&daemon, form, false, now).await;
        let v2 = ls(&daemon, form, true, now).await;
        eprintln!("--- ls {} ---\n{v2}", form.join(" "));
        if v1 != v2 {
            differ.push(format!("ls {}:\nv1:\n{v1}\nv2:\n{v2}", form.join(" ")));
        }
    }
    for ((name, v1), (_, v2)) in callers(&daemon, false).await.into_iter().zip(callers(&daemon, true).await) {
        eprintln!("--- {name} ---\n{v2}");
        if v1 != v2 {
            differ.push(format!("{name}:\nv1:\n{v1}\nv2:\n{v2}"));
        }
    }
    assert!(differ.is_empty(), "{}", differ.join("\n\n"));
    // The fixture's cases are in the output: a child of a closed parent, a stale peer row.
    let all = ls(&daemon, &["--json"], true, now).await;
    let all: Value = serde_json::from_str(&all).unwrap();
    let row = |id: &str| {
        all["sessions"].as_array().unwrap().iter().find(|r| r["sessionId"] == id).cloned().unwrap()
    };
    assert_eq!(row("c-under-closed")["spawnedBy"], "c-closed-parent");
    assert_eq!((row("c-stuck")["state"].clone(), row("c-stuck")["status"].clone()), (json!("stuck"), json!("running")));
    let running = ls(&daemon, &["--json", "--status", "running"], true, now).await;
    assert!(running.contains("c-stuck"), "--status running lists the stuck running chat: {running}");
    if peer_closed {
        // v1's own row: v1 marks no closed row stale while its peer is down
        // (`RemoteRows::mark_peer_stale`), so neither does this.
        assert_eq!(row("p-closed")["status"], "closed");
        assert!(row("p-closed").get("stale").is_none_or(|stale| stale != true));
    }
    assert_eq!(row("p-live")["stale"], true);
    let exact: Value =
        serde_json::from_str(&ls(&daemon, &["--json", "--live", "--limit", &live_text], true, now).await)
            .unwrap();
    assert_eq!(exact["nextCursor"], Value::Null);
    let more: Value =
        serde_json::from_str(&ls(&daemon, &["--json", "--live", "--limit", "1"], true, now).await)
            .unwrap();
    assert!(more["nextCursor"].is_string(), "{more}");
}

/// A walk of the whole view reads v1, whole, while another machine lists a closed row, and when
/// the status does not say; a live form walks v2 all the same (decision 213).
#[tokio::test]
async fn a_walk_of_the_whole_view_reads_v1_while_another_machines_closed_row_is_listed() {
    use crate::cli::list_read::closed_remote_listed;
    for (peer_closed, listed) in [(true, true), (false, false)] {
        let daemon = serve(Serves::List, |hub| fixture_with(hub, peer_closed)).await;
        let status = daemon.client.request(crate::rpc::method::MUX_STATUS, json!({})).await.unwrap();
        assert_eq!(closed_remote_listed(Some(&status)), listed, "{status}");
    }
    assert!(closed_remote_listed(Some(&json!({"closedListed": 3}))), "a status without the count");
    assert!(closed_remote_listed(None), "no status read");
    assert!(!closed_remote_listed(Some(&json!({"closedRemoteListed": 0}))));
}

/// A daemon without v2, one with v2 and `list` off, and one whose v2 list lacks the rows of the
/// hub machine it lists (no `listHubRows`, decision 210): each caller runs its v1 path, and
/// prints the hub machine's chat as v1 does.
#[tokio::test]
async fn each_caller_runs_its_v1_path_on_a_daemon_without_the_list() {
    for (serves, hub_machine) in
        [(Serves::NoV2, false), (Serves::ListOff, false), (Serves::List, true)]
    {
        let seed = |hub: &Hub| {
            let rows = fixture(hub);
            if hub_machine {
                let hosts = std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
                let row = crate::mesh::BookSession {
                    name: "joined".into(),
                    session_id: "m-joined".into(),
                    host: "machine-b".into(),
                    daemon_id: "inst_b".into(),
                    harness: "claude".into(),
                    state: "idle".into(),
                    last_seen_at: crate::store::now_ms(),
                };
                hub.set_mesh_book(hosts, vec![row]);
            }
            rows
        };
        let daemon = serve(serves, seed).await;
        if hub_machine {
            let listed = ls(&daemon, &["--json"], true, 0).await;
            assert!(listed.contains("m-joined"), "the hub machine's chat is listed: {listed}");
        }
        let source = Via::List(daemon.path.clone()).open(&daemon.client).await.unwrap();
        assert!(source.is_none(), "no list source on this daemon");
        for ((name, v1), (_, through)) in
            callers(&daemon, false).await.into_iter().zip(callers(&daemon, true).await)
        {
            assert_eq!(v1, through, "{name}: its v1 path");
            assert!(!through.is_empty(), "{name} printed nothing");
        }
    }
}

/// `--limit 2`, then `--cursor` with what it printed: no row twice and none skipped.
#[tokio::test]
async fn a_limit_then_its_cursor_read_every_row_once() {
    let daemon = serve(Serves::List, fixture).await;
    let now = crate::store::now_ms();
    let whole: Value = serde_json::from_str(&ls(&daemon, &["--json"], false, now).await).unwrap();
    let ids = |v: &Value| -> Vec<String> {
        v["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| format!("{}/{}", r["peer"].as_str().unwrap_or(""), r["sessionId"].as_str().unwrap()))
            .collect()
    };
    let mut read = Vec::new();
    let first: Value = serde_json::from_str(&ls(&daemon, &["--json", "--limit", "2"], true, now).await).unwrap();
    read.extend(ids(&first));
    let mut cursor = first["nextCursor"].as_str().map(str::to_owned);
    while let Some(c) = cursor {
        let page: Value =
            serde_json::from_str(&ls(&daemon, &["--json", "--limit", "2", "--cursor", &c], true, now).await)
                .unwrap();
        read.extend(ids(&page));
        cursor = page["nextCursor"].as_str().map(str::to_owned);
    }
    assert_eq!(read, ids(&whole));
}

/// A counting proxy for `daemon`'s socket: what the daemon sends to every client through it.
struct Counted {
    path: PathBuf,
    bytes: Arc<AtomicU64>,
    _dir: tempfile::TempDir,
}

async fn counted(target: PathBuf) -> Counted {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("counted.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let bytes = Arc::new(AtomicU64::new(0));
    let total = bytes.clone();
    tokio::spawn(async move {
        while let Ok((client, _)) = listener.accept().await {
            let Ok(server) = tokio::net::UnixStream::connect(&target).await else { return };
            let total = total.clone();
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let (mut client_read, mut client_write) = client.into_split();
                let (mut server_read, mut server_write) = server.into_split();
                let up = tokio::spawn(async move {
                    let _ = tokio::io::copy(&mut client_read, &mut server_write).await;
                });
                let mut buf = vec![0_u8; 64 * 1024];
                while let Ok(n) = server_read.read(&mut buf).await {
                    if n == 0 || client_write.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    total.fetch_add(n as u64, Ordering::Relaxed);
                }
                up.abort();
            });
        }
    });
    Counted { path, bytes, _dir: dir }
}

/// A hub with 20 live chats and `closed` closed ones beside them, served with the v2 list.
async fn gate_daemon(closed: usize) -> Daemon {
    serve(Serves::List, |hub| gate_rows(hub, closed)).await
}

fn gate_rows(hub: &Hub, closed: usize) -> usize {
    let now = crate::store::now_ms();
    for n in 0..20_u64 {
        let tags = json!({"area": "acpmux"});
        hub.insert_test_session(meta(&format!("live-{n:02}"), &format!("live-{n}"), "idle", now - n * 1_000, tags));
    }
    for n in 0..closed as u64 {
        hub.insert_test_session(meta(&format!("closed-{n:05}"), &format!("closed-{n}"), "closed", now - 60_000 - n, json!({})));
    }
    20 + closed
}

/// One caller's run through the v2 list on a new client of `proxy`: its wall time and the bytes
/// the daemon sent.
async fn gate_run(caller: &str, proxy: &Counted) -> (u128, u128) {
    let client = Client::connect(&proxy.path).await.unwrap();
    let via = || Via::List(proxy.path.clone());
    let before = proxy.bytes.load(Ordering::Relaxed);
    let started = Instant::now();
    match caller {
        "ls" => {
            super::ls::output(ls_args(&[]), false, &client, via(), crate::store::now_ms()).await.unwrap();
        }
        "pending" => {
            super::standard::pending_output(&client, via(), false).await.unwrap();
        }
        "send_tag_dry_run" => {
            super::fanout::targets_via(&client, via(), "area=acpmux", None).await.unwrap();
        }
        "mcp_ls" => {
            crate::acpmux_mcp::ls_via(&client, &json!({}), via()).await;
        }
        _ => unreachable!(),
    }
    let wall = started.elapsed().as_nanos();
    drop(client);
    // The client's initialize reply is counted too, alike on both sides.
    (wall, u128::from(proxy.bytes.load(Ordering::Relaxed) - before))
}

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[((values.len() * 95).div_ceil(100)).saturating_sub(1)]
}

fn emit(name: &str, small: &[Vec<u128>], god: &[Vec<u128>], unit: &str) -> (u128, u128) {
    let best = |rounds: &[Vec<u128>]| rounds.iter().map(|r| p95(&mut r.clone())).min().unwrap_or(0);
    let (small_p95, god_p95) = (best(small), best(god));
    let line =
        json!({"name": name, "small_p95": small_p95, "god_p95": god_p95, "unit": unit}).to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
    (small_p95, god_p95)
}

/// Each caller through the v2 list: 20 live chats with 11,000 closed beside them against 20 live
/// alone, bytes received and wall time within 1.2x. Both daemons first, then their rounds in
/// turn (decision 185). A read's pages not handed out stay at one or fewer (`unhanded_peak`).
#[ignore = "Linux release gate: 20 live chats beside 11,000 closed against 20 alone"]
#[tokio::test(flavor = "multi_thread")]
async fn v2_pr07b_callers() {
    let small = gate_daemon(0).await;
    let god = gate_daemon(11_000).await;
    let (small_proxy, god_proxy) = (counted(small.path.clone()).await, counted(god.path.clone()).await);
    for caller in ["ls", "pending", "send_tag_dry_run", "mcp_ls"] {
        let (mut small_wall, mut small_bytes, mut god_wall, mut god_bytes) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for _ in 0..5 {
            let (mut sw, mut sb, mut gw, mut gb) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
            for _ in 0..20 {
                let (wall, bytes) = gate_run(caller, &small_proxy).await;
                sw.push(wall);
                sb.push(bytes);
                let (wall, bytes) = gate_run(caller, &god_proxy).await;
                gw.push(wall);
                gb.push(bytes);
            }
            small_wall.push(sw);
            small_bytes.push(sb);
            god_wall.push(gw);
            god_bytes.push(gb);
        }
        for (measure, small, god, unit) in [
            ("bytes", &small_bytes, &god_bytes, "bytes"),
            ("wall", &small_wall, &god_wall, "ns"),
        ] {
            let name = format!("v2.pr07b.{caller}_{measure}");
            let (small, god) = emit(&name, small, god, unit);
            assert!(god.saturating_mul(100) <= small.saturating_mul(120), "{name}: {god} vs {small}");
        }
    }
    // The read of the live view holds at most one page it has not handed out.
    let mut source = Via::List(god.path.clone()).open(&god.client).await.unwrap().unwrap();
    let rows = source.rows(acpmux_client::wire::ListView::All, &|_| true).await.unwrap();
    assert_eq!(rows.len(), 11_020);
    assert!(source.connection().unhanded_peak() <= 1, "{}", source.connection().unhanded_peak());
    drop(god.v2);
    drop(small.v2);
}
