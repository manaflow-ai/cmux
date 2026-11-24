//! Row 7b part one's callers on a daemon in this process, served on a unix socket as the daemon
//! serves it (v1 and the v2 list on one socket, the list tee filling the index): each form
//! prints the same bytes read through the v2 list as through v1; a daemon without v2, or with
//! v2 and `list` off, gives each caller its v1 path; `--limit` and `--cursor` agree; and the
//! gates `v2_pr07b_*`.

use super::ls::LsArgs;
use crate::cli::list_read::Via;
use crate::client::Client;
use crate::hub::Hub;
use crate::test_support::list_daemon::{self, Counted, ListDaemon, Serves, emit};
use acpmux_core::life::V2;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Instant;

/// A daemon in this process on a unix socket, and a v1 client connected to it.
struct Daemon {
    _hub: Arc<Hub>,
    v2: Option<Arc<V2>>,
    path: PathBuf,
    client: Arc<Client>,
    _dir: tempfile::TempDir,
    /// The daemon's server, tee and writer: they stop when it drops.
    _tasks: cmux_scope::Scope,
}

/// A session's record (`list_daemon::meta`).
fn meta(id: &str, name: &str, status: &str, at: u64, tags: Value) -> crate::store::SessionMeta {
    list_daemon::meta(id, name, status, at, tags).unwrap()
}

/// Serves a new hub on a new socket (`list_daemon::serve`), and connects a v1 client to it.
async fn serve(serves: Serves, seed: impl FnOnce(&Hub) -> usize) -> Daemon {
    let daemon = list_daemon::serve(serves, seed).await.unwrap();
    let client = Client::connect(&daemon.path).await.unwrap();
    let ListDaemon { hub, v2, path, dir, tasks } = daemon;
    Daemon { _hub: hub, v2, path, client, _dir: dir, _tasks: tasks }
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
    add(meta(
        "c-under-closed",
        "under-closed",
        "idle",
        at(3),
        json!({"spawnedBy": "c-closed-parent"}),
    ));
    add(meta(
        "c-under-archived",
        "under-archived",
        "idle",
        at(4),
        json!({"spawnedBy": "c-archived-parent"}),
    ));
    for n in 0..6 {
        let tags = if n % 2 == 0 { json!({"area": "acpmux"}) } else { json!({}) };
        add(meta(&format!("c-live-{n}"), &format!("chat-{n}"), "idle", at(10 + n), tags));
    }
    for n in 0..5 {
        add(meta(
            &format!("c-old-{n}"),
            &format!("old-{n}"),
            "closed",
            at(30 + n),
            json!({"area": "acpmux"}),
        ));
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
            crate::acpmux_mcp::ls_via(client, &json!({"status": "closed"}), via())
                .await
                .to_string(),
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
        vec!["--archived"],
        vec!["--json", "--archived"],
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
    for ((name, v1), (_, v2)) in
        callers(&daemon, false).await.into_iter().zip(callers(&daemon, true).await)
    {
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
    assert_eq!(
        (row("c-stuck")["state"].clone(), row("c-stuck")["status"].clone()),
        (json!("stuck"), json!("running"))
    );
    let running = ls(&daemon, &["--json", "--status", "running"], true, now).await;
    assert!(
        running.contains("c-stuck"),
        "--status running lists the stuck running chat: {running}"
    );
    if peer_closed {
        // v1's own row: v1 marks no closed row stale while its peer is down
        // (`RemoteRows::mark_peer_stale`), so neither does this.
        assert_eq!(row("p-closed")["status"], "closed");
        assert!(row("p-closed").get("stale").is_none_or(|stale| stale != true));
    }
    assert_eq!(row("p-live")["stale"], true);
    let exact: Value = serde_json::from_str(
        &ls(&daemon, &["--json", "--live", "--limit", &live_text], true, now).await,
    )
    .unwrap();
    assert_eq!(exact["nextCursor"], Value::Null);
    let more: Value =
        serde_json::from_str(&ls(&daemon, &["--json", "--live", "--limit", "1"], true, now).await)
            .unwrap();
    assert!(more["nextCursor"].is_string(), "{more}");
}

/// `ls --archived` lists only the archived chats, here and on the v2 list alike, newest archive
/// first, with `archivedAt` (null for an older client's `1`) and `archivedBy`.
#[tokio::test]
async fn ls_archived_lists_only_the_archived_chats() {
    let daemon = serve(Serves::List, |hub| {
        let rows = fixture(hub);
        let tags = json!({"archived": "1700000000000", "archivedBy": "auto"});
        hub.insert_test_session(meta("c-settled", "settled", "closed", 1_600_000_000_000, tags));
        rows + 1
    })
    .await;
    let now = 1_700_000_000_000 + 2 * 3_600_000;
    for v2 in [false, true] {
        let rows: Value =
            serde_json::from_str(&ls(&daemon, &["--json", "--archived"], v2, now).await).unwrap();
        let rows = rows["sessions"].as_array().unwrap();
        let names: Vec<&str> = rows.iter().map(|r| r["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["settled", "archived-parent"], "v2: {v2}");
        assert_eq!(rows[0]["archivedAt"], 1_700_000_000_000_u64);
        assert_eq!(rows[0]["archivedBy"], "auto");
        assert_eq!(rows[1]["archivedAt"], Value::Null);
        assert_eq!(rows[1]["archivedBy"], "person");
        let text = ls(&daemon, &["--archived"], v2, now).await;
        assert!(text.starts_with("NAME"), "{text}");
        assert!(text.contains("settled") && text.contains("2h ago"), "{text}");
        assert!(!text.contains("closed-parent"), "{text}");
    }
}

/// A walk of the whole view reads v1, whole, while another machine lists a closed row, and when
/// the status does not say; a live form walks v2 all the same (decision 213).
#[tokio::test]
async fn a_walk_of_the_whole_view_reads_v1_while_another_machines_closed_row_is_listed() {
    use crate::cli::list_read::closed_remote_listed;
    for (peer_closed, listed) in [(true, true), (false, false)] {
        let daemon = serve(Serves::List, |hub| fixture_with(hub, peer_closed)).await;
        let status =
            daemon.client.request(crate::rpc::method::MUX_STATUS, json!({})).await.unwrap();
        assert_eq!(closed_remote_listed(Some(&status)), listed, "{status}");
    }
    assert!(closed_remote_listed(Some(&json!({"closedListed": 3}))), "a status without the count");
    assert!(closed_remote_listed(None), "no status read");
    assert!(!closed_remote_listed(Some(&json!({"closedRemoteListed": 0}))));
}

/// A daemon without v2, and one with v2 and `list` off: each caller runs its v1 path. A daemon
/// that lists a hub machine names `listHubRows` since row 5h, so its callers walk v2 and print
/// the hub machine's chat as v1 does. A daemon without `listHubRows` that lists a hub machine
/// takes v1 (decision 210).
#[tokio::test]
async fn each_caller_runs_its_v1_path_on_a_daemon_without_the_list() {
    use crate::cli::list_read::{HUB_ROWS, hub_rows_missing};
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
                    ..Default::default()
                };
                hub.set_mesh_book(hosts, vec![row]);
            }
            rows
        };
        let daemon = serve(serves, seed).await;
        let source = Via::List(daemon.path.clone()).open(&daemon.client).await.unwrap();
        assert_eq!(source.is_some(), hub_machine, "a list source only on the daemon with the list");
        assert_eq!(daemon.client.daemon_lists(HUB_ROWS), hub_machine, "listHubRows with the list");
        let hub_peer = [json!({"via": "hub"})];
        assert_eq!(
            hub_rows_missing(&daemon.client, Some(&hub_peer)).await.unwrap(),
            !hub_machine,
            "a hub machine's rows are missing only without listHubRows"
        );
        assert!(!hub_rows_missing(&daemon.client, Some(&[])).await.unwrap(), "no hub machine");
        if hub_machine {
            for v2 in [false, true] {
                let listed = ls(&daemon, &["--json"], v2, 0).await;
                assert!(listed.contains("m-joined"), "the hub machine's chat is listed: {listed}");
            }
        }
        for ((name, v1), (_, through)) in
            callers(&daemon, false).await.into_iter().zip(callers(&daemon, true).await)
        {
            assert_eq!(v1, through, "{name}: the same on both paths");
            assert!(!through.is_empty(), "{name} printed nothing");
        }
    }
}

/// `--limit 2`, then `--cursor` with what it printed: no row twice and none skipped.
/// `ls` lists every machine's sessions: with a peer's row in the list it has a stderr line that
/// says so and names `--machine local`; with this machine's rows only it has none. Its stdout
/// is the same bytes either way, and stays parseable JSON (2026-11-20: a boot hook read a
/// fleet-wide `ls --json` as its own sessions).
#[tokio::test]
async fn ls_says_on_stderr_when_its_rows_span_machines_and_stdout_is_unchanged() {
    let daemon = serve(Serves::List, fixture).await;
    let now = crate::store::now_ms();
    for v2 in [false, true] {
        let via = || if v2 { Via::List(daemon.path.clone()) } else { Via::V1 };
        for (argv, json_out, spans) in [
            (&[][..], true, true),
            (&["--live"][..], true, true),
            (&["--fields", "name,status"][..], false, true),
            (&[][..], false, true),
            (&["--machine", "local"][..], true, false),
            (&["--machine", "local", "--fields", "name"][..], false, false),
            (&["far/*"][..], true, true),
        ] {
            let (out, scope) =
                super::ls::scoped_output(ls_args(argv), json_out, &daemon.client, via(), now)
                    .await
                    .unwrap();
            let plain = super::ls::output(ls_args(argv), json_out, &daemon.client, via(), now)
                .await
                .unwrap();
            assert_eq!(out, plain, "stdout of ls {argv:?} is the same with the notice");
            assert!(!out.contains("--machine local lists"), "the notice never reaches stdout");
            if json_out {
                serde_json::from_str::<Value>(&out).expect("stdout stays JSON");
            }
            match scope {
                Some(line) if spans => {
                    assert!(line.starts_with("ls: "), "{line}");
                    assert!(line.ends_with("--machine local lists only this one"), "{line}");
                }
                None if !spans => {}
                other => panic!("ls {argv:?} (v2 {v2}): scope {other:?}, spans {spans}"),
            }
        }
    }
    let (_, scope) =
        super::ls::scoped_output(ls_args(&[]), true, &daemon.client, Via::V1, now).await.unwrap();
    // Every row of the fixture's: this machine's and the peer `far`'s.
    let rows: Value = serde_json::from_str(&ls(&daemon, &["--json"], false, now).await).unwrap();
    let n = rows["sessions"].as_array().unwrap().len();
    assert_eq!(
        scope.as_deref(),
        Some(
            format!("ls: {n} sessions on 2 machines; --machine local lists only this one").as_str()
        )
    );
}

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
            .map(|r| {
                format!("{}/{}", r["peer"].as_str().unwrap_or(""), r["sessionId"].as_str().unwrap())
            })
            .collect()
    };
    let mut read = Vec::new();
    let first: Value =
        serde_json::from_str(&ls(&daemon, &["--json", "--limit", "2"], true, now).await).unwrap();
    read.extend(ids(&first));
    let mut cursor = first["nextCursor"].as_str().map(str::to_owned);
    while let Some(c) = cursor {
        let page: Value = serde_json::from_str(
            &ls(&daemon, &["--json", "--limit", "2", "--cursor", &c], true, now).await,
        )
        .unwrap();
        read.extend(ids(&page));
        cursor = page["nextCursor"].as_str().map(str::to_owned);
    }
    assert_eq!(read, ids(&whole));
}

/// A send relay whose listing sleeps 30 s gives this daemon's rows anyway, at once: exit 0,
/// under 2 s, one stderr line naming what is not listed, `remote.state` "missing". With a kept
/// listing, its rows are merged and marked stale (Leo, 2026-11-22: "we need it to be able to run
/// blazingly fast under duress"; `ls` exited 1 after 15 s while `lane-gh sessions` stalled).
#[tokio::test]
async fn a_stalled_relay_never_holds_or_fails_the_local_listing() {
    use crate::cli::ls_far::{self, FAR_BUDGET};
    let daemon = serve(Serves::List, fixture).await;
    let now = crate::store::now_ms();
    let plain: Value = serde_json::from_str(&ls(&daemon, &["--json"], false, now).await).unwrap();
    let local = plain["sessions"].as_array().unwrap().len();
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(ls_far::CACHE_FILE);
    let stalled = || ls_far::tests::stalled_relay();
    let far = |relay| {
        ls_far::start_with(Some(relay), cache.clone(), Some(daemon.client.clone()), FAR_BUDGET)
    };

    let started = Instant::now();
    let (out, line) = super::ls::scoped_output_with_far(
        ls_args(&[]),
        true,
        &daemon.client,
        Via::V1,
        now,
        far(stalled()),
    )
    .await
    .expect("the local listing never fails for a far read");
    let took = started.elapsed();
    assert!(took < std::time::Duration::from_secs(2), "ls took {took:?} with a stalled relay");
    let v: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["sessions"].as_array().unwrap().len(), local, "every local row is listed");
    assert_eq!(v["remote"]["state"], "missing");
    let line = line.unwrap();
    assert!(
        line.starts_with(
            "acpmux: other machines' sessions through sh: not read within 1.5s; not listed\n"
        ),
        "{line}"
    );

    // A kept listing is merged, its rows with their asOfMs (not `stale`: no down peer's), and said on
    // stderr with its age.
    let row = json!({"peer": "relayed-vm", "sessionId": "r-1", "name": "relayed-vm/worker", "status": "idle", "updatedAt": now - 1});
    ls_far::write_cache(&cache, "sh", &[row], now - 120_000);
    // With a kept listing the relay is not waited on at all.
    let started = Instant::now();
    let (out, line) = super::ls::scoped_output_with_far(
        ls_args(&[]),
        true,
        &daemon.client,
        Via::V1,
        now,
        far(stalled()),
    )
    .await
    .unwrap();
    let v: Value = serde_json::from_str(&out).unwrap();
    let rows = v["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), local + 1);
    let cached = rows.iter().find(|r| r["sessionId"] == "r-1").unwrap();
    assert!(cached.get("stale").is_none(), "{cached}");
    assert_eq!(cached["asOfMs"], now - 120_000);
    assert_eq!(v["remote"]["state"], "stale");
    assert_eq!(v["remote"]["asOfMs"], now - 120_000);
    let took = started.elapsed();
    assert!(
        took < std::time::Duration::from_millis(500),
        "a kept listing waited on the relay: {took:?}"
    );
    assert!(line.unwrap().contains("from the last listing, refreshing; listed as of 2m ago"));

    // The text view prints the local rows too, under the same budget.
    let started = Instant::now();
    let (text, _) = super::ls::scoped_output_with_far(
        ls_args(&["--all"]),
        false,
        &daemon.client,
        Via::V1,
        now,
        far(stalled()),
    )
    .await
    .unwrap();
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
    assert!(text.contains("chat-0"), "{text}");
}

/// A counting proxy for `daemon`'s socket: what the daemon sends to every client through it.
async fn counted(target: PathBuf) -> Counted {
    list_daemon::counted(target).await.unwrap()
}

/// A hub with 20 live chats and `closed` closed ones beside them, served with the v2 list.
async fn gate_daemon(closed: usize) -> Daemon {
    serve(Serves::List, |hub| list_daemon::twenty_live_beside(hub, closed).unwrap()).await
}

/// One caller's run through the v2 list on a new client of `proxy`: its wall time and the bytes
/// the daemon sent. Past the clock, the run's connections end (`Counted::settled`) before the
/// bytes are read, so they are all the daemon sent.
async fn gate_run(caller: &str, proxy: &Counted) -> (u128, u128) {
    let client = Client::connect(&proxy.path).await.unwrap();
    let via = || Via::List(proxy.path.clone());
    let before = proxy.bytes.load(Ordering::Relaxed);
    let started = Instant::now();
    // The MCP `ls` answers a refusal as a value, never an error: kept, and checked past the clock.
    let mcp_reply = match caller {
        "ls" => {
            super::ls::output(ls_args(&[]), false, &client, via(), crate::store::now_ms())
                .await
                .unwrap();
            None
        }
        "pending" => {
            super::standard::pending_output(&client, via(), false).await.unwrap();
            None
        }
        "send_tag_dry_run" => {
            super::fanout::targets_via(&client, via(), "area=acpmux", None).await.unwrap();
            None
        }
        "mcp_ls" => Some(crate::acpmux_mcp::ls_via(&client, &json!({}), via()).await),
        _ => unreachable!(),
    };
    let wall = started.elapsed().as_nanos();
    drop(client);
    // A timed sample proves it did the work (decision 271): a refused `ls` is no fast `ls`.
    if let Some(reply) = mcp_reply {
        assert_eq!(reply["isError"], json!(false), "the gate's MCP ls was refused: {reply}");
        let sessions = reply["structuredContent"]["sessions"].as_array().map(Vec::len);
        assert_eq!(sessions, Some(20), "the gate's MCP ls lists its 20 live chats");
    }
    proxy.settled().await.unwrap();
    // The client's initialize reply is counted too, alike on both sides.
    (wall, u128::from(proxy.bytes.load(Ordering::Relaxed) - before))
}

/// Each caller through the v2 list: 20 live chats with 11,000 closed beside them against 20 live
/// alone, bytes received and wall time within 1.2x. Both daemons first, then their rounds in
/// turn (decision 185). A read's pages not handed out stay at one or fewer (`unhanded_peak`).
#[ignore = "Linux release gate: 20 live chats beside 11,000 closed against 20 alone"]
#[tokio::test(flavor = "multi_thread")]
async fn v2_pr07b_callers() {
    let small = gate_daemon(0).await;
    let god = gate_daemon(11_000).await;
    let (small_proxy, god_proxy) =
        (counted(small.path.clone()).await, counted(god.path.clone()).await);
    let fds = list_daemon::open_fds();
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
            list_daemon::assert_fds_given_back(&format!("v2.pr07b.{caller}"), fds);
        }
        // Round one's samples, where a cost a fixture builds up would land first.
        let (small_one, god_one) = (&small_wall[0], &god_wall[0]);
        eprintln!("v2.pr07b.{caller}_wall round 1: small {small_one:?} god {god_one:?}");
        for (measure, small, god, unit) in
            [("bytes", &small_bytes, &god_bytes, "bytes"), ("wall", &small_wall, &god_wall, "ns")]
        {
            let name = format!("v2.pr07b.{caller}_{measure}");
            let (small, god) = emit(&name, small, god, unit);
            assert!(
                god.saturating_mul(100) <= small.saturating_mul(120),
                "{name}: {god} vs {small}"
            );
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

/// A hub for the usage pass's gate: [`list_daemon::usage_beside`] with `closed` rows closed two
/// days ago or more, settled (decision 284): its order built, and two passes run, the first
/// finding each chat's transcript and the second reading nothing new.
async fn usage_gate_daemon(closed: usize) -> (ListDaemon, tempfile::TempDir) {
    let store = tempfile::tempdir().unwrap();
    let path = store.path().to_path_buf();
    let daemon = list_daemon::serve(Serves::NoV2, |hub| {
        list_daemon::usage_beside(hub, closed, &path).unwrap()
    })
    .await
    .unwrap();
    daemon.hub.warm_list_order_for_test();
    for _ in 0..2 {
        daemon.hub.usage_pass_due_for_test();
        daemon.hub.refresh_usage_stats().await;
    }
    daemon.hub.warm_list_order_for_test();
    (daemon, store)
}

/// Row `v2.pr07b.usage_first_read`: a usage pass (`Hub::refresh_usage_stats`, which `ls --json`,
/// `--wide`, `_acpmux/info` and `_acpmux/sessions {usage: true}` wait for), wall time within 1.2x
/// with 110,000 closed rows beside the same live and closed-today chats against 1,100. Each
/// timed sample is a pass that ran over the same 16 chats on both sides (decision 271), each
/// side holds the closed rows its name says (decision 278), and the kept list order is patched,
/// never sorted again, in every sample. Both hubs settled first, then their rounds in turn.
#[ignore = "Linux release gate: a usage pass at 110,000 closed rows against 1,100"]
#[tokio::test(flavor = "multi_thread")]
async fn v2_pr07b_usage_first_read() {
    let sources = list_daemon::USAGE_LIVE + list_daemon::USAGE_CLOSED_TODAY;
    let (small, _small_store) = usage_gate_daemon(1_100).await;
    let (god, _god_store) = usage_gate_daemon(110_000).await;
    for (side, closed) in [(&small, 1_100), (&god, 110_000)] {
        let sessions = side.hub.session_handles();
        let shut = sessions
            .iter()
            .filter(|s| s.read_meta(|m| m.status == crate::store::SessionStatus::Closed))
            .count();
        assert_eq!(sessions.len() - shut, list_daemon::USAGE_LIVE, "live chats");
        assert_eq!(shut, closed + list_daemon::USAGE_CLOSED_TODAY, "closed rows");
    }
    let built = [small.hub.list_order_rebuilds_for_test(), god.hub.list_order_rebuilds_for_test()];
    let (mut small_wall, mut god_wall) = (Vec::new(), Vec::new());
    for _ in 0..5 {
        let (mut sw, mut gw) = (Vec::new(), Vec::new());
        for _ in 0..20 {
            for (side, walls) in [(&small, &mut sw), (&god, &mut gw)] {
                side.hub.usage_pass_due_for_test();
                // One row told before each pass: every timed sample pays a patch of the order.
                side.hub.tell_row_for_test("today-00");
                let (passes, _) = side.hub.usage_passes_for_test();
                let started = Instant::now();
                side.hub.refresh_usage_stats().await;
                walls.push(started.elapsed().as_nanos());
                assert_eq!(side.hub.usage_passes_for_test(), (passes + 1, sources), "a pass ran");
            }
        }
        small_wall.push(sw);
        god_wall.push(gw);
    }
    let rebuilt =
        [small.hub.list_order_rebuilds_for_test(), god.hub.list_order_rebuilds_for_test()];
    assert_eq!(rebuilt, built, "a timed pass sorted every chat again");
    // The row's rounds and line last (`emit` prints both), with no assert after it: the home
    // judges the ratio.
    emit("v2.pr07b.usage_first_read", &small_wall, &god_wall, "ns");
}

/// One in-process daemon for [`probe_order_at_start`]: `aged` is the usage gate's fixture
/// ([`list_daemon::usage_beside`]), `recent` is [`list_daemon::twenty_live_beside`] (every closed
/// chat a minute old). Its kept list order is put back unsorted, as a deferred start holds it
/// before its start task runs.
async fn order_probe_daemon(fixture: &str, closed: usize) -> (ListDaemon, tempfile::TempDir) {
    let store = tempfile::tempdir().unwrap();
    let path = store.path().to_path_buf();
    let daemon = list_daemon::serve(Serves::NoV2, |hub| match fixture {
        "aged" => list_daemon::usage_beside(hub, closed, &path).unwrap(),
        _ => list_daemon::twenty_live_beside(hub, closed).unwrap(),
    })
    .await
    .unwrap();
    daemon.hub.unsort_list_order_for_test();
    (daemon, store)
}

/// The first reader in a deferred start's window (the daemon answers, its logs are not read
/// yet), at 1,100 and 110,000 closed chats, in µs. `before`: nothing has sorted the kept list
/// order, so the reader sorts every chat (as before the start task sorted it). `after`: the start
/// task's first step (`Hub::sort_list_order`, `daemon.rs`) ran, timed as `window`, then the
/// reader. Readers: `_acpmux/info {usage:true}` and a first `_acpmux/sessions` page of 20. Then
/// `recent_F`: a first usage pass with the order sorted, every closed chat a minute old (all
/// candidates), and its candidates read as #43807 deduped them and as now (`recent_candidates`).
/// One daemon alive at a time. Prints `PROBE` lines, asserts nothing of the times.
#[ignore = "probe: the first reader in a deferred start's window at 1,100 and 110,000 closed chats"]
#[tokio::test(flavor = "multi_thread")]
async fn probe_order_at_start() {
    let us = |at: Instant| at.elapsed().as_micros();
    let keys: Vec<String> = (0..list_daemon::USAGE_LIVE).map(|n| format!("live-{n:02}")).collect();
    for closed in [1_100, 110_000] {
        for reader in ["info_usage", "page"] {
            for case in ["before", "after"] {
                let (d, store) = order_probe_daemon("aged", closed).await;
                let window = if case == "after" {
                    let at = Instant::now();
                    d.hub.sort_list_order();
                    us(at)
                } else {
                    0
                };
                let client = Client::connect(&d.path).await.unwrap();
                let (method, params) = match reader {
                    "info_usage" => (
                        crate::rpc::method::MUX_INFO,
                        json!({"sessionIds": keys, "row": true, "usage": true}),
                    ),
                    _ => (crate::rpc::method::MUX_SESSIONS, json!({"limit": 20})),
                };
                let at = Instant::now();
                let reply = client.request(method, params).await.unwrap();
                let first = us(at);
                assert!(reply.is_object(), "{reply}");
                eprintln!(
                    "PROBE closed={closed} reader={reader} case={case} window_us={window} \
                     first_reader_us={first} rebuilds={}",
                    d.hub.list_order_rebuilds_for_test()
                );
                drop(client);
                drop(d);
                drop(store);
            }
        }
    }
    let (d, store) = order_probe_daemon("recent", 110_000).await;
    d.hub.sort_list_order();
    let at = Instant::now();
    d.hub.refresh_usage_stats().await;
    let pass = us(at);
    // Candidates both ways, each read three times on the same patched order.
    for round in 1..=3 {
        let (copied, live, count) = d.hub.usage_candidates_both_for_test();
        eprintln!(
            "PROBE closed=110000 part=recent_candidates round={round} copied_ids_us={copied} \
             live_set_us={live} candidates={count}"
        );
    }
    eprintln!(
        "PROBE closed=110000 part=recent_F first_us={pass} passes={:?}",
        d.hub.usage_passes_for_test()
    );
    drop(d);
    drop(store);
}
