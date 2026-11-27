use super::*;

fn host(name: &str, ok: bool, load: bool, room: f64, live: u64) -> Value {
    json!({"name": name, "local": false, "ok": ok, "load": load, "room": room, "live": live})
}

#[test]
fn auto_picks_the_peer_with_most_room_never_this_machine_and_spreads_a_batch() {
    let hosts = vec![
        json!({"name": "here", "local": true, "ok": true, "load": false, "room": 9.0, "live": 0}),
        host("a", true, false, 2.0, 1),
        host("b", true, false, 1.0, 0),
    ];
    let mut placed = HashMap::new();
    assert_eq!(choose(&hosts, &placed, |_| true).as_deref(), Some("a"));
    placed.insert("a".to_owned(), 1.0);
    // a and b both have one lane left now; b runs fewer agents.
    assert_eq!(choose(&hosts, &placed, |_| true).as_deref(), Some("b"));
}

#[test]
fn a_full_fleet_takes_the_move_on_the_least_loaded_host_but_never_a_reserved_or_role_refused_one() {
    let hosts = vec![
        // Refused for its role or a reservation: `load` false.
        json!({"name": "held", "local": false, "ok": false, "load": false, "room": 5.0, "live": 0,
               "reserved": "reserved for someone until 2026-10-30T20:50:00Z"}),
        host("busy", false, true, 0.0, 9),
        host("quieter", false, true, 0.0, 3),
    ];
    assert_eq!(choose(&hosts, &HashMap::new(), |_| true).as_deref(), Some("quieter"));
    assert_eq!(choose(&hosts, &HashMap::new(), |n| n != "quieter").as_deref(), Some("busy"));
    assert_eq!(choose(&hosts, &HashMap::new(), |n| n == "held"), None);
}

#[test]
fn the_forward_is_a_unix_socket_forward_that_fails_at_once_and_ends_options_before_the_host() {
    let argv = forward_argv("gcp-1", Path::new("/tmp/x/d.sock"), "/home/cmux/.acpmux/acpmux.sock");
    let at = |s: &str| argv.iter().position(|a| a == s).unwrap();
    assert!(argv.contains(&"ExitOnForwardFailure=yes".to_owned()), "{argv:?}");
    // Its own connection, never the fleet config's shared master for the host (item D).
    assert_eq!(argv[at("ControlMaster=no") - 1], "-o", "{argv:?}");
    assert_eq!(argv[at("ControlPath=none") - 1], "-o", "{argv:?}");
    assert!(at("ControlPath=none") < at("--"), "{argv:?}");
    assert_eq!(argv[at("-L") + 1], "/tmp/x/d.sock:/home/cmux/.acpmux/acpmux.sock");
    assert_eq!(argv[at("--") + 1], "gcp-1");
    assert_eq!(argv.last().unwrap(), "gcp-1");
}

#[test]
fn the_targets_answer_is_taken_only_as_plain_absolute_paths() {
    let ok = parse_about("/home/cmux\n{\"socket\":\"/home/cmux/.acpmux/acpmux.sock\"}\n").unwrap();
    assert_eq!(
        (ok.home.as_str(), ok.socket.as_str()),
        ("/home/cmux", "/home/cmux/.acpmux/acpmux.sock")
    );
    assert!(parse_about("/home/cmux\n\n").is_err(), "no status: no socket is guessed");
    assert!(
        parse_about("/home/cmux\n{\"socket\":\"/tmp/a:b\"}\n").is_err(),
        "a colon would split -L"
    );
    assert!(parse_about("home\n{}\n").is_err());
    assert!(parse_about("/home/x y\n{}\n").is_err());
}

#[test]
fn a_named_target_must_be_an_ssh_peer() {
    let peers = json!({"peers": [{"name": "gcp-1", "url": "ssh://gcp-1"}, {"name": "web", "url": "wss://x"}]});
    assert!(Targets::new("gcp-1", &peers).is_ok());
    assert!(Targets::new("GCP-1", &peers).is_ok(), "peer names match case-blind");
    let e = Targets::new("web", &peers).err().unwrap().to_string();
    assert!(e.contains("not an ssh peer"), "{e}");
    assert!(Targets::new("auto", &peers).is_ok());
}

fn about_ok(free_gb: Option<u64>) -> RemoteDaemon {
    RemoteDaemon {
        home: "/home/cmux".into(),
        socket: "/home/cmux/.acpmux/acpmux.sock".into(),
        disk_free: free_gb.map(|g| g * 1_000_000_000),
        harnesses: None,
        rate: None,
        copy_secs: None,
    }
}

fn targets(names: &[&str]) -> Vec<Target> {
    names
        .iter()
        .map(|n| Target { name: (*n).to_owned(), ssh: (*n).to_owned(), probed: None })
        .collect()
}

/// A full fleet ranked a pool slot first (no room anywhere, fewest agents there), but its
/// fresh ssh fails (no VM behind it): auto passes it over with why and takes the next host
/// that answers, and remembers it as unreachable.
#[test]
fn auto_passes_over_a_host_a_fresh_ssh_cannot_reach() {
    let hosts = vec![
        host("fs-slot", false, true, 0.0, 2),
        host("lane-a", false, true, 0.0, 6),
        json!({"name": "spare", "local": false, "ok": false, "load": false, "room": 9.0,
               "live": 0, "refused": "not a lane host (no lanes entry in fleet-registry.json)"}),
    ];
    let (order, skipped) = ranked(&hosts, &HashMap::new(), |_| None);
    assert_eq!(order, ["fs-slot", "lane-a"], "the ranking alone still puts the slot first");
    assert_eq!(
        skipped,
        [(
            "spare".to_owned(),
            "not a lane host (no lanes entry in fleet-registry.json)".to_owned()
        )]
    );
    let mut asked = Vec::new();
    let w = walk(
        &targets(&order.iter().map(String::as_str).collect::<Vec<_>>()),
        0,
        "claude",
        |_| 0,
        |t| {
            asked.push(t.name.clone());
            if t.name == "fs-slot" {
                Err("ssh to fs-slot failed: cloud-vm-up: pool slot fs-slot has no VM".into())
            } else {
                Ok(about_ok(Some(100)))
            }
        },
    );
    assert_eq!(asked, ["fs-slot", "lane-a"]);
    let pick = w.pick.unwrap();
    assert_eq!(pick.name, "lane-a");
    assert!(pick.probed.is_some(), "the pick carries its answer, so the move does not ask again");
    assert_eq!(w.skipped.len(), 1);
    assert_eq!(w.skipped[0].0, "fs-slot");
    assert!(
        w.skipped[0].1.starts_with("unreachable from here (ssh to fs-slot failed: cloud-vm-up"),
        "{:?}",
        w.skipped
    );
    assert_eq!(w.unreachable.len(), 1);
    assert!(w.warning.is_none());
}

/// No host answers: no pick, and every host is named with why.
#[test]
fn auto_with_no_host_that_answers_picks_none_and_says_why_for_each() {
    let w = walk(
        &targets(&["a", "b"]),
        0,
        "claude",
        |_| 0,
        |t| Err(format!("ssh to {} failed", t.name)),
    );
    assert!(w.pick.is_none());
    let names: Vec<&str> = w.skipped.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["a", "b"]);
}

/// A host whose free disk, less the move, is under its floor is passed over for one with room;
/// when every host that answers is short, the one with the most free takes it with a warning.
/// A host that gives no disk reading is taken.
#[test]
fn auto_passes_over_a_host_short_of_disk_unless_every_host_is() {
    let gb = 1_000_000_000u64;
    let disk = |n: &str| match n {
        "tight" => Some(12),
        "roomy" => Some(200),
        "tighter" => Some(11),
        _ => None,
    };
    let floor = |_: &str| 10 * gb;
    let w = walk(&targets(&["tight", "roomy"]), 3 * gb, "claude", floor, |t| {
        Ok(about_ok(disk(&t.name)))
    });
    assert_eq!(w.pick.unwrap().name, "roomy");
    assert_eq!(w.skipped[0].0, "tight");
    assert!(
        w.skipped[0].1.contains("12.0 GB disk free, under its 10 GB floor plus this move's 3.0 GB"),
        "{:?}",
        w.skipped
    );
    assert!(w.unreachable.is_empty() && w.warning.is_none());

    let w = walk(&targets(&["tighter", "tight"]), 3 * gb, "claude", floor, |t| {
        Ok(about_ok(disk(&t.name)))
    });
    assert_eq!(w.pick.unwrap().name, "tight", "most free of the short ones");
    assert!(w.warning.unwrap().contains("disk floors only warn"));

    let w = walk(&targets(&["unread"]), 3 * gb, "claude", floor, |t| Ok(about_ok(disk(&t.name))));
    assert_eq!(w.pick.unwrap().name, "unread");
}

/// A host the caller rules out (not an ssh peer, held) is listed with its reason, not ranked.
#[test]
fn ranked_names_each_host_it_leaves_out() {
    let hosts = vec![host("a", true, false, 2.0, 1), host("held", true, false, 5.0, 0)];
    let (order, skipped) = ranked(&hosts, &HashMap::new(), |n| {
        (n == "held").then(|| "reserved for sam until x (r)".to_owned())
    });
    assert_eq!(order, ["a"]);
    assert_eq!(skipped, [("held".to_owned(), "reserved for sam until x (r)".to_owned())]);
}

#[test]
fn the_targets_disk_reading_is_optional_and_in_bytes() {
    let r = parse_about("/home/cmux\n{\"socket\":\"/s.sock\"}\n2048\n").unwrap();
    assert_eq!(r.disk_free, Some(2048 * 1024));
    let r = parse_about("/home/cmux\n{\"socket\":\"/s.sock\"}\n").unwrap();
    assert_eq!(r.disk_free, None, "an older answer without df");
    let r = parse_about("/home/cmux\n{\"socket\":\"/s.sock\"}\nnot a number\n").unwrap();
    assert_eq!(r.disk_free, None);
}

#[test]
fn the_tree_size_sums_blobs_and_skips_submodules() {
    let listing = b"100644 blob aaaa     120\tsrc/a.rs\x00100755 blob bbbb       5\tbin/x\x00160000 commit cccc       -\tvendor/sub\x00";
    assert_eq!(sum_tree_sizes(listing), 125);
    assert_eq!(sum_tree_sizes(b""), 0);
}

/// A git checkout on branch `lane/x` with an `origin`, in a fresh temp folder.
fn repo_with_branch() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| {
        let ok = StdCommand::new("git").arg("-C").arg(dir.path()).args(args).output().unwrap();
        assert!(ok.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&ok.stderr));
    };
    run(&["init", "-q", "-b", "lane/x"]);
    run(&["remote", "add", "origin", "git@github.com:manaflow-ai/cmux.git"]);
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    std::fs::write(dir.path().join("sub/a.txt"), "a").unwrap();
    run(&["add", "."]);
    run(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a"]);
    dir
}

#[test]
fn a_source_machines_checkout_reads_as_this_machines_does() {
    // `--from`: the checkout script runs on the source machine; here it runs in a local shell,
    // and reads the same checkout `checkout_of` reads here.
    let repo = repo_with_branch();
    let sub = repo.path().join("sub");
    let read = |cwd: &Path| {
        let out = run_here(CHECKOUT_SCRIPT, format!("{}\n", cwd.display()).as_bytes()).unwrap();
        assert!(out.ok, "{}", out.stderr);
        parse_checkout(&out.stdout).unwrap()
    };
    let there = read(&sub).expect("a checkout");
    assert_eq!(Some(there.clone()), checkout_of(&sub).unwrap());
    assert_eq!(there.branch.as_deref(), Some("lane/x"));
    assert_eq!(there.origin.as_deref(), Some("git@github.com:manaflow-ai/cmux.git"));
    assert!(!there.dirty);

    std::fs::write(sub.join("b.txt"), "b").unwrap();
    assert!(read(&sub).unwrap().dirty);

    let plain = tempfile::tempdir().unwrap();
    assert_eq!(read(plain.path()), None);
}

#[test]
fn a_repository_with_no_origin_and_no_commit_moves_as_a_plain_folder() {
    // Every lane VM's home is `git init`ed and never committed: a chat there has nothing to
    // bundle, so both reads say no checkout and plan_folder makes it Folder::Plain.
    let dir = tempfile::tempdir().unwrap();
    let ok =
        StdCommand::new("git").arg("-C").arg(dir.path()).args(["init", "-q"]).output().unwrap();
    assert!(ok.status.success());
    std::fs::write(dir.path().join("loose.txt"), "x").unwrap();
    let out = run_here(CHECKOUT_SCRIPT, format!("{}\n", dir.path().display()).as_bytes()).unwrap();
    assert!(out.ok, "{}", out.stderr);
    assert_eq!(parse_checkout(&out.stdout).unwrap(), None);
    assert_eq!(checkout_of(dir.path()).unwrap(), None);
    // With an origin it is still a checkout (its branch is pushed, or refused, as before).
    let ok = StdCommand::new("git")
        .arg("-C")
        .arg(dir.path())
        .args(["remote", "add", "origin", "git@github.com:manaflow-ai/cmux.git"])
        .output()
        .unwrap();
    assert!(ok.status.success());
    assert!(checkout_of(dir.path()).unwrap().is_some());
}

#[test]
fn a_checkout_answer_without_a_plain_top_folder_is_refused() {
    assert!(parse_checkout("branch\tmain\n").is_err());
    assert!(parse_checkout("top\t/a/../b\nbranch\tmain\n").is_err());
    assert_eq!(parse_checkout("none\n").unwrap(), None);
}

#[test]
fn local_names_this_machine_only() {
    assert!(names_here("local", "lawbook"));
    assert!(names_here("LawBook", "lawbook"));
    assert!(!names_here("cmux-lawrence", "lawbook"));
}

#[test]
fn this_machine_is_the_target_of_a_move_from_another_without_being_a_peer() {
    let here = Target { name: "lawbook".into(), ssh: String::new(), probed: Some(about_ok(None)) };
    let targets = Targets::with_here("local", &json!({"peers": []}), Some(here)).unwrap();
    assert_eq!(targets.named.as_deref(), Some("lawbook"));
    // Without --from, `local` is no peer.
    assert!(Targets::new("local", &json!({"peers": []})).is_err());
}

#[test]
fn a_folder_is_made_on_this_machine_for_a_move_here() {
    let base = tempfile::tempdir().unwrap();
    let want = base.path().join("teleport/eval");
    let made =
        prepare_folder("", &Folder::Plain { cwd: want.to_string_lossy().into_owned() }, None)
            .unwrap();
    assert_eq!(Path::new(&made), want.canonicalize().unwrap());
}

#[test]
fn folder_failure_keeps_a_clear_reason_when_stderr_is_empty() {
    let error = folder_failure(
        "gcp-agent-lane-3",
        &crate::cli::hosts::RemoteOut { ok: false, stdout: String::new(), stderr: String::new() },
    );
    let text = error.to_string();
    assert!(text.contains("making the folder on gcp-agent-lane-3 failed"));
    assert!(text.contains("non-zero exit status"));
    assert!(text.contains("remote command returned no diagnostic output"));
}

#[test]
fn folder_failure_uses_stdout_when_stderr_is_empty() {
    let error = folder_failure(
        "gcp-agent-lane-3",
        &crate::cli::hosts::RemoteOut {
            ok: false,
            stdout: "wt: worktree already exists\n".into(),
            stderr: String::new(),
        },
    );
    assert!(error.to_string().contains("wt: worktree already exists"));
}

#[cfg(unix)]
#[tokio::test]
async fn move_dry_run_reports_running_and_dirty_together_without_changing_the_chat_or_checkout() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    for (running, carry_changes, detached, expected) in [
        (true, false, false, Some("running_turn")),
        (false, false, false, Some("dirty_worktree")),
        (false, true, false, None),
        (false, false, true, None),
    ] {
        let repo = repo_with_branch();
        let file = repo.path().join("sub/a.txt");
        std::fs::write(&file, "uncommitted work").unwrap();
        if detached {
            let out = StdCommand::new("git")
                .arg("-C")
                .arg(repo.path())
                .args(["checkout", "--detach", "--quiet"])
                .output()
                .unwrap();
            assert!(out.status.success());
        }
        let info = json!({"sessionId": "chat", "name": "Chat", "cwd": repo.path(),
            "status": if running { "running" } else { "ready" },
            "turn": if running { json!({"turnId": "one"}) } else { Value::Null },
            "queued": 2});
        let socket_dir = tempfile::tempdir().unwrap();
        let socket = socket_dir.path().join("daemon.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (rd, mut wr) = stream.into_split();
            let mut lines = BufReader::new(rd).lines();
            for expected in [method::INITIALIZE, method::MUX_INFO, method::MUX_INFO] {
                let line = lines.next_line().await.unwrap().unwrap();
                let Message::Request { id, method: called, .. } = Message::parse(&line).unwrap()
                else {
                    panic!("expected read-only request");
                };
                assert_eq!(called, expected, "dry run must not cancel or freeze the chat");
                let result = if called == method::INITIALIZE { json!({}) } else { info.clone() };
                wr.write_all(Message::ok(id, result).to_line().as_bytes()).await.unwrap();
            }
        });
        // The target's daemon: a dry run that gets as far as a plan asks it, read-only, whether
        // it takes the chat (`target_ask`), and nothing else.
        let target_socket = socket_dir.path().join("target.sock");
        let target_listener = tokio::net::UnixListener::bind(&target_socket).unwrap();
        let target_server = tokio::spawn(async move {
            let (stream, _) = target_listener.accept().await.unwrap();
            let (rd, mut wr) = stream.into_split();
            let mut lines = BufReader::new(rd).lines();
            // The client's own initialize, then the move's (whose reply it keeps).
            let asked = [method::INITIALIZE, method::INITIALIZE, "_acpmux/transfer_preflight"];
            for expected in asked {
                let line = lines.next_line().await.unwrap().unwrap();
                let Message::Request { id, method: called, params } =
                    Message::parse(&line).unwrap()
                else {
                    panic!("expected read-only request");
                };
                assert_eq!(called, expected, "a dry run only asks the target");
                if called != method::INITIALIZE {
                    assert_eq!(params.unwrap_or_default()["manifest"]["sessionId"], "chat");
                }
                let result = json!({"takes": true});
                wr.write_all(Message::ok(id, result).to_line().as_bytes()).await.unwrap();
            }
        });
        let client = Client::connect(&socket).await.unwrap();
        let about =
            RemoteDaemon { socket: target_socket.to_string_lossy().into_owned(), ..about_ok(None) };
        let target = Target { name: "target".into(), ssh: String::new(), probed: Some(about) };
        let mut targets =
            Targets::with_here("target", &json!({"peers": []}), Some(target)).unwrap();
        let args = MoveArgs {
            sessions: vec!["chat".into()],
            host: "target".into(),
            all_idle: false,
            interrupt: false,
            after_turn: true,
            turn_timeout: DEFAULT_TURN_TIMEOUT,
            leave_dirty: false,
            carry_changes,
            cwd: None,
            dry_run: true,
            resume_there: false,
            from: None,
            slow_ok: false,
            from_snapshot: false,
            as_harness: None,
        };
        let outcome = move_one(&client, "chat", &args, repo.path(), &mut targets).await;
        assert_eq!(outcome.error_code, expected);
        assert_eq!(outcome.preflight.running, running);
        assert_eq!(outcome.preflight.dirty, Some(true));
        assert!(!outcome.moved);
        assert_eq!(std::fs::read_to_string(file).unwrap(), "uncommitted work");
        if detached {
            assert!(outcome.error.unwrap().contains("detached HEAD"));
        } else {
            assert_eq!(outcome.error.is_some(), expected.is_some());
        }
        server.await.unwrap();
        if expected.is_none() && !detached {
            target_server.await.expect("the planned dry run asked the target");
        } else {
            // Refused before a plan: the target was never reached.
            target_server.abort();
        }
    }
}

#[test]
fn move_from_auto_excludes_source_registry_and_ssh_aliases() {
    let peers = json!({"peers": [
        {"name": "source", "url": "ssh://source-host"},
        {"name": "source-alias", "url": "ssh://other-route"},
        {"name": "same-endpoint", "url": "ssh://source-host"},
        {"name": "target", "url": "ssh://target-host"}
    ]});
    let registry = json!({"machines": {"source": {"aliases": ["source-alias"]}}});
    let source = Source::Peer {
        name: "SOURCE.local".into(),
        ssh: "source-host".into(),
        socket: "/remote/acpmux.sock".into(),
    };
    let mut targets = Targets::new("auto", &peers).unwrap();
    targets.exclude_source(&source, Some(&registry)).unwrap();
    let hosts = json!([
        {"name": "source", "ok": true, "room": 100},
        {"name": "source-alias", "ok": true, "room": 100},
        {"name": "same-endpoint", "ok": true, "room": 100},
        {"name": "target", "ok": true, "room": 1}
    ]);
    let (order, _) = ranked(hosts.as_array().unwrap(), &HashMap::new(), |name| {
        targets.target(name).is_none().then(|| "not a destination".into())
    });
    assert_eq!(order, ["target"]);
    for alias in ["source", "source-alias", "same-endpoint"] {
        let mut targets = Targets::new(alias, &peers).unwrap();
        assert!(targets.exclude_source(&source, Some(&registry)).is_err());
    }
}

#[cfg(unix)]
#[tokio::test]
async fn move_from_reads_placement_from_the_initiating_daemon() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let sockets = tempfile::tempdir().unwrap();
    let local_path = sockets.path().join("local.sock");
    let remote_path = sockets.path().join("remote.sock");
    let local = tokio::net::UnixListener::bind(&local_path).unwrap();
    let remote = tokio::net::UnixListener::bind(&remote_path).unwrap();
    let local_server = tokio::spawn(async move {
        let (stream, _) = local.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        for expected in [method::INITIALIZE, "_acpmux/place"] {
            let line = lines.next_line().await.unwrap().unwrap();
            let Message::Request { id, method: called, .. } = Message::parse(&line).unwrap() else {
                panic!("expected placement request");
            };
            assert_eq!(called, expected);
            // No local candidates: Auto should refuse, without probing any remote-only peer.
            wr.write_all(Message::ok(id, json!({"hosts": []})).to_line().as_bytes()).await.unwrap();
        }
    });
    let remote_server = tokio::spawn(async move {
        let (stream, _) = remote.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        let line = lines.next_line().await.unwrap().unwrap();
        let Message::Request { id, method: called, .. } = Message::parse(&line).unwrap() else {
            panic!("expected initialize");
        };
        assert_eq!(called, method::INITIALIZE);
        wr.write_all(Message::ok(id, json!({})).to_line().as_bytes()).await.unwrap();
        assert!(
            lines.next_line().await.unwrap().is_none(),
            "placement must not query the source daemon's peers"
        );
    });
    let observer = Client::connect(&local_path).await.unwrap();
    let source = Client::connect(&remote_path).await.unwrap();
    let mut targets = Targets::new("auto", &json!({"peers": []})).unwrap();
    targets.observer = Some(observer);
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        targets.pick(&source, Path::new("/project"), 0, "claude", 0),
    )
    .await
    .expect("local placement answered");
    assert!(result.err().unwrap().to_string().contains("no peer can take"));
    local_server.await.unwrap();
    // Client owns a background reader; stop the fixture rather than wait for that task to close.
    remote_server.abort();
}

/// A host that lists its harnesses without the chat's is passed over for one that has it, with
/// why; one that lists none (an older build) is still taken, and its receive decides.
#[test]
fn auto_passes_over_a_host_without_the_chats_harness() {
    let with = |ids: Option<&[&str]>| RemoteDaemon {
        harnesses: ids.map(|ids| ids.iter().map(|s| (*s).to_owned()).collect()),
        ..about_ok(Some(100))
    };
    let w = walk(
        &targets(&["fs-lane", "gcp-lane"]),
        0,
        "claude-sr2",
        |_| 0,
        |t| {
            Ok(if t.name == "fs-lane" {
                with(Some(&["claude"]))
            } else {
                with(Some(&["claude", "claude-sr2"]))
            })
        },
    );
    assert_eq!(w.pick.unwrap().name, "gcp-lane");
    assert_eq!(w.skipped.len(), 1);
    assert_eq!(w.skipped[0].0, "fs-lane");
    assert!(
        w.skipped[0].1.contains("agent \"claude-sr2\" is not configured there"),
        "{:?}",
        w.skipped
    );
    assert!(w.unreachable.is_empty(), "a missing harness is not an unreachable host");

    let w = walk(&targets(&["old"]), 0, "claude-sr2", |_| 0, |_| Ok(with(None)));
    assert_eq!(w.pick.unwrap().name, "old", "a host that lists no harnesses is not refused here");
}

/// The about script's fourth line is `acpmux harness list --json`: its ids are the harnesses.
#[test]
fn about_reads_the_targets_harness_ids() {
    let out = "/home/cmux\n{\"socket\":\"/home/cmux/.acpmux/acpmux.sock\"}\n1024\n{\"diagnostics\":[],\"harnesses\":[{\"id\":\"claude\"},{\"id\":\"claude-sr2\"}]}\n";
    let r = parse_about(out).unwrap();
    assert_eq!(r.disk_free, Some(1024 * 1024));
    assert_eq!(r.harnesses.as_deref(), Some(&["claude".to_owned(), "claude-sr2".to_owned()][..]));
    assert!(r.lacks("claude-sr2").is_none());
    assert!(r.lacks("codex").unwrap().contains("not configured there"));
    let old = parse_about("/home/cmux\n{\"socket\":\"/s\"}\n1024\n").unwrap();
    assert!(old.harnesses.is_none() && old.lacks("claude-sr2").is_none());
}

/// 2026-11-22: a 7 GB chat went to a host reached through a ~96 KB/s relay (about 6 h of copy)
/// when another took about 1 MB/s. A host whose copy is estimated past `SLOW_COPY` is passed
/// over, with why, for one that is not; when only slow hosts answer, the fastest is the pick
/// (the move then refuses it without `--slow-ok`).
#[test]
fn auto_passes_over_a_host_whose_copy_takes_hours() {
    let wire = super::link::wire_bytes(6_800_000_000);
    let at = |rate: f64| RemoteDaemon {
        rate: Some(rate),
        copy_secs: Some(super::link::copy_secs(wire, rate)),
        ..about_ok(Some(100))
    };
    let w = walk(
        &targets(&["relayed", "direct"]),
        0,
        "claude",
        |_| 0,
        |t| Ok(at(if t.name == "relayed" { 96_000.0 } else { 1_000_000.0 })),
    );
    assert_eq!(w.pick.unwrap().name, "direct");
    assert_eq!(w.skipped.len(), 1);
    assert!(w.skipped[0].1.contains("96 KB/s"), "{:?}", w.skipped);
    let w = walk(
        &targets(&["slower", "slow"]),
        0,
        "claude",
        |_| 0,
        |t| Ok(at(if t.name == "slower" { 50_000.0 } else { 96_000.0 })),
    );
    assert_eq!(w.pick.unwrap().name, "slow");
    assert!(w.warning.unwrap().contains("slow"));
}

#[test]
fn the_run_error_names_each_chat_that_did_not_move_and_why() {
    let moved = Outcome::new("a1");
    let mut refused = Outcome::new("claude-13");
    refused.error = Some("a turn is running; the move takes it along".into());
    let mut lost = Outcome::new("s-2");
    lost.name = "optchat".into();
    lost.error = Some("transfer.busy: the running turn did not stop".into());
    assert!(not_moved(&[moved]).is_none(), "every chat moved");
    let why = not_moved(&[Outcome::new("a1"), refused, lost]).unwrap().message;
    assert!(why.starts_with("2 of 3 chats did not move: "), "{why}");
    assert!(why.contains("claude-13 (claude-13): a turn is running"), "{why}");
    assert!(why.contains("optchat (s-2): transfer.busy: the running turn did not stop"), "{why}");
}

/// Item C (a `--cwd --after-turn` move sat 12 minutes with no output): every wait prints a line
/// at least every 5 s naming the chat and the step, and none while the step is quick.
#[tokio::test(start_paused = true)]
async fn a_wait_says_what_it_waits_for_every_five_seconds() {
    let mut said = Vec::new();
    let slow = tokio::time::sleep(std::time::Duration::from_secs(17));
    let out = progress_every(
        PROGRESS_EVERY,
        async {
            slow.await;
            7
        },
        |secs| said.push(progress_line("Chat", "waiting for its running turn to end", secs)),
    )
    .await;
    assert_eq!(out, 7);
    assert_eq!(
        said,
        [5, 10, 15]
            .map(|s| format!("move: Chat: waiting for its running turn to end ({s}s so far)"))
    );
    let mut quiet = 0;
    progress_every(PROGRESS_EVERY, async {}, |_| quiet += 1).await;
    assert_eq!(quiet, 0);
}

/// Item C: `--after-turn` waits at most `--timeout` (sent as `afterTurnTimeoutMs`, which the
/// daemon bounds its own wait by), and the failure names the chat and the step, non-zero.
#[cfg(unix)]
#[tokio::test]
async fn after_turn_waits_at_most_its_timeout_and_names_the_chat_and_step() {
    use crate::rpc::{Message, RpcError};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let socket_dir = tempfile::tempdir().unwrap();
    let socket = socket_dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        loop {
            let line = lines.next_line().await.unwrap().unwrap();
            let Message::Request { id, method: called, params, .. } =
                Message::parse(&line).unwrap()
            else {
                panic!("expected a request");
            };
            if called == method::INITIALIZE {
                wr.write_all(Message::ok(id, json!({})).to_line().as_bytes()).await.unwrap();
                continue;
            }
            assert_eq!(called, "_acpmux/transfer_begin");
            let params = params.unwrap_or_default();
            assert_eq!(params["afterTurn"], true);
            assert_eq!(params["afterTurnTimeoutMs"], 1000);
            let e = RpcError::invalid_params(
                "the running turn did not end within 1s; try again, or pass --interrupt",
            );
            wr.write_all(Message::err(id, e).to_line().as_bytes()).await.unwrap();
            return;
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let args = MoveArgs {
        sessions: vec!["chat".into()],
        host: "target".into(),
        all_idle: false,
        interrupt: false,
        after_turn: true,
        turn_timeout: std::time::Duration::from_secs(1),
        slow_ok: false,
        leave_dirty: false,
        carry_changes: false,
        cwd: Some("/srv/x".into()),
        dry_run: false,
        resume_there: false,
        from: None,
        from_snapshot: false,
        as_harness: None,
    };
    let mut src = MoveEnd::new("source", &client, None);
    let e = match begin_waiting(&mut src, "chat", "Chat", None, &args, None).await {
        Ok(_) => panic!("a turn that outlasts --timeout must not move"),
        Err(e) => format!("{e:#}"),
    };
    assert!(e.starts_with("Chat: step `wait for the running turn` gave up"), "{e}");
    assert!(e.contains("within 1s (--timeout)"), "{e}");
    server.await.unwrap();
}

/// Item C: `--timeout` parses, 600 s by default.
#[test]
fn move_timeout_defaults_to_ten_minutes() {
    use crate::cli::command::{Cli, Command, flatten};
    use clap::Parser as _;
    let parse = |argv: &[&str]| match flatten(Cli::try_parse_from(argv).unwrap().command.unwrap()) {
        Command::MoveSessions(a) => a.timeout,
        _ => panic!("not a move"),
    };
    assert_eq!(parse(&["acpmux", "session", "move", "a", "--machine", "m", "--after-turn"]), 600);
    assert_eq!(
        parse(&[
            "acpmux",
            "session",
            "move",
            "a",
            "--machine",
            "m",
            "--after-turn",
            "--timeout",
            "30"
        ]),
        30
    );
}

/// Item B: a move from a checkout on `main` never pushes `main`. Its HEAD (with a commit origin
/// does not have) goes under a move's own ref outside `refs/heads`, the target checks that
/// commit out detached, and the ref is deleted after; origin's `main` and branch list are as
/// they were.
#[cfg(unix)]
#[test]
fn a_move_from_main_pushes_a_snapshot_ref_never_main_and_lands_detached() {
    let git = |dir: &Path, args: &[&str]| {
        let out = StdCommand::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let base = tempfile::tempdir().unwrap();
    let origin = base.path().join("origin.git");
    std::fs::create_dir(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare"]);
    let src = base.path().join("src");
    git(base.path(), &["clone", "-q", origin.to_str().unwrap(), "src"]);
    std::fs::write(src.join("a.txt"), "a").unwrap();
    git(&src, &["add", "a.txt"]);
    git(&src, &["commit", "-q", "-m", "a"]);
    git(&src, &["push", "-q", "origin", "main"]);
    git(&src, &["remote", "set-head", "origin", "main"]);
    let main_before = git(&origin, &["rev-parse", "refs/heads/main"]);
    // A commit only this checkout has, on main.
    std::fs::write(src.join("b.txt"), "b").unwrap();
    git(&src, &["add", "b.txt"]);
    git(&src, &["commit", "-q", "-m", "b"]);
    let head = git(&src, &["rev-parse", "HEAD"]);

    let c = checkout_of(&src).unwrap().expect("a checkout");
    assert_eq!(c.default_branch.as_deref(), Some("main"));
    let home = Path::new("/nowhere");
    let url = origin.to_string_lossy().into_owned();
    let c = Checkout { origin: Some(url.clone()), ..c };
    let folder = match plan::plan_folder(&src, home, Some(&c), "/h", false, None) {
        // A local path is no GitHub remote: build the worktree folder the plan makes for one.
        Ok(f @ Folder::Worktree { snapshot: true, .. }) => f,
        _ => Folder::Worktree {
            repo: "o/r".into(),
            url: url.clone(),
            branch: "main".into(),
            subdir: String::new(),
            dirty: false,
            snapshot: plan::shared_branch("main", c.default_branch.as_deref()),
        },
    };
    assert!(matches!(folder, Folder::Worktree { snapshot: true, .. }), "{folder:?}");

    let dest = snapshot_ref();
    assert!(dest.starts_with("refs/acpmux/moves/"), "{dest}");
    // The push script refuses any other ref: never refs/heads/main through a snapshot.
    let refused = run_here(PUSH_SCRIPT, format!("{}\nrefs/tags/x\n", src.display()).as_bytes());
    assert!(!refused.unwrap().ok);
    assert_eq!(push_branch(&src, &dest).unwrap(), head);
    assert_eq!(git(&origin, &["rev-parse", "refs/heads/main"]), main_before, "main never pushed");
    assert_eq!(git(&origin, &["rev-parse", &dest]), head);

    // The target's side: WORKTREE_SCRIPT with PATH holding `bin` (a stand-in `wt`, or none).
    let target = |case: &str, wt: Option<&str>| {
        let target_home = base.path().join(format!("target-home-{case}"));
        let bin = target_home.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        if let Some(body) = wt {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::write(bin.join("wt"), body).unwrap();
            std::fs::set_permissions(bin.join("wt"), std::fs::Permissions::from_mode(0o755))
                .unwrap();
        }
        let mut child = StdCommand::new("/bin/sh")
            .arg("-c")
            .arg(WORKTREE_SCRIPT)
            .env("HOME", &target_home)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("WT_STANDIN_URL", &url)
            .env("WT_STANDIN_REF", &dest)
            .env("WT_STANDIN_LOG", target_home.join("wt.log"))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            use std::io::Write as _;
            let input = format!("o/r\nmain\n{url}\n\n{dest}\n{head}\n");
            child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        }
        let out = child.wait_with_output().unwrap();
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert!(out.status.success(), "{case}: {stderr}");
        let there =
            PathBuf::from(String::from_utf8_lossy(&out.stdout).lines().last().unwrap().trim());
        assert_eq!(git(&there, &["rev-parse", "HEAD"]), head, "{case}");
        let symbolic = StdCommand::new("git")
            .arg("-C")
            .arg(&there)
            .args(["symbolic-ref", "-q", "HEAD"])
            .status()
            .unwrap();
        assert!(!symbolic.success(), "{case}: the target's checkout is detached");
        assert!(there.join("b.txt").exists(), "{case}");
        let notes: Vec<String> =
            stderr.lines().filter_map(|l| l.strip_prefix(FOLDER_NOTE).map(str::to_owned)).collect();
        let log = std::fs::read_to_string(target_home.join("wt.log")).unwrap_or_default();
        (notes, log)
    };
    let short = &head[..12];
    // No `wt`: a clone of its own, and the move says so.
    let (notes, _) = target("no-wt", None);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].starts_with("no wt on PATH; cloning"), "{notes:?}");
    // A `wt` that refuses the commit as the real one does (a commit on no branch is not in its
    // partial-clone mirror): the clone, and a line naming why, never a silent fallback.
    let refusing = "#!/bin/sh\necho \"$*\" >> \"$WT_STANDIN_LOG\"\n\
        echo \"wt: refused: $4 is not in this partial clone\" >&2\nexit 1\n";
    let (notes, log) = target("wt-refuses", Some(refusing));
    assert_eq!(log.trim(), format!("new o/r --at {head} --name move-{short}"));
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].starts_with(&format!("wt new --at {short} failed")), "{notes:?}");
    // A `wt` that makes the checkout: used as it is, with nothing to say.
    let making = "#!/bin/sh\necho \"$*\" >> \"$WT_STANDIN_LOG\"\n\
        d=\"$HOME/wt-made\"; git clone -q --no-checkout -- \"$WT_STANDIN_URL\" \"$d\" >&2 || exit 1\n\
        git -C \"$d\" fetch -q origin \"$WT_STANDIN_REF\" >&2 || exit 1\n\
        git -C \"$d\" -c advice.detachedHead=false checkout -q --detach \"$4\" >&2 || exit 1\n\
        echo \"wt: made $d\"\necho \"$d\"\n";
    let (notes, log) = target("wt-makes", Some(making));
    assert_eq!(log.trim(), format!("new o/r --at {head} --name move-{short}"));
    assert!(notes.is_empty(), "{notes:?}");

    drop_ref(&src, &dest);
    assert!(git(&origin, &["for-each-ref", "refs/acpmux"]).is_empty(), "the move's ref is gone");
    assert_eq!(
        git(&origin, &["for-each-ref", "--format=%(refname)", "refs/heads"]),
        "refs/heads/main"
    );
}

#[test]
fn origin_head_names_the_default_branch() {
    assert_eq!(origin_head("origin/main").as_deref(), Some("main"));
    assert_eq!(origin_head("origin/feat-cmux-next\n").as_deref(), Some("feat-cmux-next"));
    assert_eq!(origin_head("").as_deref(), None);
    let read = parse_checkout("top\t/w\nbranch\tmain\ndefault\torigin/main\n").unwrap().unwrap();
    assert_eq!(read.default_branch.as_deref(), Some("main"));
}

/// Item A: `--machine auto` never moves a chat to a machine the registry marks a person's own
/// (never a dependency: leo-apps, interactive), a last-resort host, or a reserved one; a peer
/// whose only fault is a stale build is ranked, with the one command that refreshes it said.
#[test]
fn auto_never_picks_a_personal_last_resort_or_reserved_machine_and_ranks_a_stale_build() {
    let until = "2999-01-01T00:00:00Z";
    let reg = json!({
        "machines": {
            "own-box": {"roles": ["leo-apps"], "lanes": {"max_lanes": 6}},
            "desk": {"interactive": true},
            "spare": {"lanes": {"last_resort": true}},
            "booked": {"lanes": {"max_lanes": 6}, "hold": {"reason": "reserved", "until": until}},
            "lane": {"lanes": {"max_lanes": 6}},
            "old": {"lanes": {"max_lanes": 6}}
        }
    });
    for n in ["own-box", "desk"] {
        let why = auto_refusal(n, true, Some(&reg)).expect(n);
        assert!(why.contains("never a dependency"), "{n}: {why}");
    }
    assert!(auto_refusal("spare", true, Some(&reg)).unwrap().contains("lanes.last_resort"));
    assert!(auto_refusal("booked", true, Some(&reg)).is_some(), "a reserved machine");
    assert_eq!(auto_refusal("lane", true, Some(&reg)), None);
    assert!(auto_refusal("lane", false, Some(&reg)).unwrap().contains("not an ssh peer"));

    let hosts = vec![
        host("own-box", true, false, 9.0, 0),
        host("old", true, false, 5.0, 0),
        host("lane", true, false, 2.0, 0),
        host("spare", true, false, 8.0, 0),
    ];
    let mut hosts = hosts;
    hosts[1]["outdated"] = json!(true);
    hosts[1]["refresh"] = json!("acpmux machine update old");
    let (order, skipped) = ranked(&hosts, &HashMap::new(), |n| auto_refusal(n, true, Some(&reg)));
    assert_eq!(order, ["old", "lane"], "{skipped:?}");
    let passed: Vec<&str> = skipped.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(passed, ["own-box", "spare"]);
    let lines = outdated_lines(&hosts, &order);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("auto: old runs another acpmux build"), "{}", lines[0]);
    assert!(lines[0].ends_with("refresh it with `acpmux machine update old`"), "{}", lines[0]);
}

/// Item D: a move ends only once this machine lists the moved chats reachable on their new
/// machine; a last-known copy, or a row whose peer is reconnecting, is not yet. Past the bound
/// it says why instead of waiting on. F3: the chats of one move are waited on together, one
/// request for all still waited on, not one bounded wait per chat.
#[tokio::test(start_paused = true)]
#[cfg(unix)]
async fn a_move_ends_once_its_chats_are_listed_reachable_where_they_went() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let row = |id: &str, stale: bool, state: &str| {
        vec![
            json!({"sessionId": id, "status": "closed", "movedTo": {"host": "t"}}),
            json!({"sessionId": id, "peer": "t", "stale": stale, "peerState": state}),
        ]
    };
    let rows = |parts: Vec<Vec<Value>>| json!({"rows": parts.concat()});
    // s2 is listed reachable at the second ask, s1 at the fourth.
    let replies = [
        rows(vec![]),
        rows(vec![row("s1", true, "reconnecting"), row("s2", false, "connected")]),
        rows(vec![row("s1", false, "reconnecting")]),
        rows(vec![row("s1", false, "connected")]),
    ];
    let socket_dir = tempfile::tempdir().unwrap();
    let socket = socket_dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        let mut asked = Vec::new();
        while let Ok(Some(line)) = lines.next_line().await {
            let Message::Request { id, method: called, params, .. } =
                Message::parse(&line).unwrap()
            else {
                panic!("expected a request");
            };
            if called == method::INITIALIZE {
                wr.write_all(Message::ok(id, json!({})).to_line().as_bytes()).await.unwrap();
                continue;
            }
            if called == "_acpmux/peers" {
                let peers = json!({"peers": [{"name": "t", "link": "reconnecting"}]});
                wr.write_all(Message::ok(id, peers).to_line().as_bytes()).await.unwrap();
                continue;
            }
            assert_eq!(called, method::MUX_INFO);
            asked.push(params.unwrap_or_default()["sessionIds"].clone());
            let reply = replies
                .get(asked.len() - 1)
                .cloned()
                .unwrap_or_else(|| rows(vec![row("s1", false, "reconnecting")]));
            wr.write_all(Message::ok(id, reply).to_line().as_bytes()).await.unwrap();
        }
        asked
    });
    let client = Client::connect(&socket).await.unwrap();
    let poll = std::time::Duration::from_millis(250);
    let bound = std::time::Duration::from_secs(20);
    let both = vec![("t/s1".to_owned(), "s1".to_owned()), ("t/s2".to_owned(), "s2".to_owned())];
    let started = tokio::time::Instant::now();
    assert_eq!(await_arrival(&client, &both, bound, poll).await, vec![]);
    assert_eq!(started.elapsed(), 3 * poll, "one wait for both, ended when the last arrived");
    // A link that stays down: the wait ends at its bound and says why, per chat.
    let one = vec![("t/s1".to_owned(), "s1".to_owned())];
    let late = await_arrival(&client, &one, std::time::Duration::from_secs(1), poll).await;
    assert_eq!(late, vec![("s1".to_owned(), "peer reconnecting".to_owned())]);
    drop(client);
    let asked = server.await.unwrap();
    assert_eq!(
        asked[..4],
        [json!(["t/s1", "t/s2"]), json!(["t/s1", "t/s2"]), json!(["t/s1"]), json!(["t/s1"])]
    );
    assert!((4 + 4..=4 + 5).contains(&asked.len()), "asked {} times", asked.len());

    let one_row = |stale, state| rows(vec![row("s1", stale, state)]);
    assert_eq!(arrived(&rows(vec![]), "s1"), Err("not listed here yet".to_owned()));
    let stale = arrived(&one_row(true, "reconnecting"), "s1").unwrap_err();
    assert!(stale.contains("last-known copy"), "{stale}");
    assert_eq!(arrived(&one_row(false, "degraded"), "s1"), Ok(()));
    // Another chat's row says nothing of this one.
    assert_eq!(arrived(&one_row(false, "connected"), "s2"), Err("not listed here yet".to_owned()));
    assert_eq!(arrived(&json!({"rows": [{"sessionId": "s1", "status": "idle"}]}), "s1"), Ok(()));
    assert_eq!(
        arrived(&json!({"rows": [{"sessionId": "s1", "status": "closed"}]}), "s1"),
        Err("listed here as closed".to_owned())
    );
}

/// A move to a peer whose link is offline (never reached, its attempts failed) ends at once,
/// naming why, instead of waiting out the arrival bound: no row comes from that link within
/// it, and the wait cost every such move the whole 5 s (the published move bench's floor).
/// A chat on a local key or a peer on its way back is still waited on.
#[tokio::test(start_paused = true)]
#[cfg(unix)]
async fn a_move_to_an_offline_peer_does_not_wait_out_the_arrival_bound() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let socket_dir = tempfile::tempdir().unwrap();
    let socket = socket_dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Message::Request { id, method: called, .. } = Message::parse(&line).unwrap() else {
                panic!("expected a request");
            };
            let reply = match called.as_str() {
                "_acpmux/peers" => json!({"peers": [
                    {"name": "gone", "link": "offline", "error": "SSH connection refused"},
                    {"name": "back", "link": "reconnecting"}]}),
                _ => json!({"rows": []}),
            };
            wr.write_all(Message::ok(id, reply).to_line().as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let poll = std::time::Duration::from_millis(50);
    let bound = std::time::Duration::from_secs(5);
    let started = tokio::time::Instant::now();
    let one = vec![("gone/s1".to_owned(), "s1".to_owned())];
    let late = await_arrival(&client, &one, bound, poll).await;
    assert_eq!(late, vec![("s1".to_owned(), "peer offline: SSH connection refused".to_owned())]);
    assert_eq!(started.elapsed(), std::time::Duration::ZERO, "no poll waited");
    // With a chat on a peer on its way back, that one is still waited on to the bound.
    let both =
        vec![("gone/s1".to_owned(), "s1".to_owned()), ("back/s2".to_owned(), "s2".to_owned())];
    let started = tokio::time::Instant::now();
    let late = await_arrival(&client, &both, bound, poll).await;
    assert_eq!(late[0], ("s1".to_owned(), "peer offline: SSH connection refused".to_owned()));
    assert_eq!(late[1].0, "s2");
    assert!(started.elapsed() >= bound - poll, "{:?}", started.elapsed());
    assert_eq!(
        link_gone(&json!({"peers": [{"name": "x", "link": "authFailed"}]}), "x").as_deref(),
        Some("peer authFailed")
    );
    assert_eq!(link_gone(&json!({"peers": [{"name": "x", "link": "connecting"}]}), "x"), None);
    assert_eq!(link_gone(&json!({"peers": []}), "x"), None);
}

fn outcome(name: &str, error: Option<&str>) -> Outcome {
    Outcome {
        session: format!("id-{name}"),
        name: name.into(),
        host: Some("vm".into()),
        cwd: None,
        moved: error.is_none(),
        there: None,
        resumed: Ok(false),
        carried: None,
        error: error.map(str::to_owned),
        error_code: None,
        preflight: preflight::Preflight::default(),
        arrival_key: None,
        reachable: None,
    }
}

/// A move with a chat that did not move ends with each such chat and why, in the message (text
/// output) and as `data.failed` in `--json`'s error envelope: it once said only "1 of 1 chats did
/// not move", the reason nowhere a caller read.
#[test]
fn a_chat_that_did_not_move_names_its_reason_in_the_moves_error() {
    assert!(not_moved(&[outcome("ok", None)]).is_none());
    let e = not_moved(&[outcome("ok", None), outcome("demo", Some("ssh to vm failed"))]).unwrap();
    assert!(e.message.starts_with("1 of 2 chats did not move: demo (id-demo): ssh to vm failed"));
    assert!(e.text().contains("ssh to vm failed"), "text output: {}", e.text());
    let env = e.envelope();
    let failed = env
        .get("error")
        .and_then(|e| e.get("data"))
        .and_then(|d| d.get("failed"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    assert_eq!(failed.len(), 1, "{env}");
    let row = failed.first().cloned().unwrap_or_default();
    assert_eq!(row.get("session").and_then(Value::as_str), Some("id-demo"));
    assert_eq!(row.get("reason").and_then(Value::as_str), Some("ssh to vm failed"));
}

/// A chat in a git repository with no remote (dirty) moves: its branches go as a bundle into a
/// fresh repository at the same path under the target's home, its uncommitted work applied, and
/// no remote is added on either side. A second move to the same place goes beside it. Before,
/// every such chat failed with "has no origin remote to push".
#[cfg(unix)]
#[test]
fn a_repo_with_no_remote_moves_as_a_bundle_with_its_changes_and_no_remote() {
    let git = |dir: &Path, args: &[&str]| {
        let out = StdCommand::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let base = tempfile::tempdir().unwrap();
    let home = base.path().join("home");
    let src = home.join("scratch").join("demo");
    std::fs::create_dir_all(src.join("sub")).unwrap();
    git(&src, &["init", "-q"]);
    std::fs::write(src.join("sub").join("a.txt"), "a").unwrap();
    git(&src, &["add", "."]);
    git(&src, &["commit", "-q", "-m", "a"]);
    git(&src, &["branch", "side"]);
    git(&src, &["tag", "v1"]);
    // Uncommitted: a change and an untracked file.
    std::fs::write(src.join("sub").join("a.txt"), "a2").unwrap();
    std::fs::write(src.join("new.txt"), "n").unwrap();
    let head = git(&src, &["rev-parse", "HEAD"]);

    let home = home.canonicalize().unwrap();
    let src = src.canonicalize().unwrap();
    let c = checkout_of(&src.join("sub")).unwrap().expect("a checkout");
    assert!(c.origin.is_none() && c.dirty);
    let target_home = base.path().join("target-home");
    std::fs::create_dir(&target_home).unwrap();
    let target_home = target_home.canonicalize().unwrap();
    let th = target_home.to_string_lossy().into_owned();
    let folder = plan::plan_folder(&src.join("sub"), &home, Some(&c), &th, true, None).unwrap();
    let Folder::Bundle { top, branch, subdir, dirty: true } = &folder else {
        panic!("{folder:?}");
    };
    assert_eq!(Path::new(top), target_home.join("scratch/demo"));

    let (commit, bundle) = read_bundle(None, &c.top).unwrap();
    assert_eq!(commit, head);
    let read = carry::snapshot(&|script, input| run_here(script, input), &c.top, true).unwrap();
    carry::check_base(&read, &commit).unwrap();
    let there = unbundle_folder("", top, branch, subdir, &commit, &bundle).unwrap();
    assert_eq!(Path::new(&there), target_home.join("scratch/demo/sub"));
    apply_carry("", &there, &read).unwrap();

    let new = target_home.join("scratch/demo");
    assert_eq!(git(&new, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&new, &["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(git(&new, &["for-each-ref", "--format=%(refname)"]).lines().count(), 3);
    assert_eq!(std::fs::read_to_string(new.join("sub/a.txt")).unwrap(), "a2");
    assert_eq!(std::fs::read_to_string(new.join("new.txt")).unwrap(), "n");
    assert!(git(&new, &["remote"]).is_empty(), "no remote on the target's repository");
    assert!(git(&src, &["remote"]).is_empty(), "no remote added to the person's repository");
    assert_eq!(git(&src, &["rev-parse", "HEAD"]), head, "the source is as it was");

    // The folder is taken now: a second move makes a fresh one beside it, never into it.
    let again = unbundle_folder("", top, branch, "", &commit, &bundle).unwrap();
    assert_ne!(Path::new(&again), new.as_path());
    assert!(again.starts_with(&format!("{top}.moved.")), "{again}");
    assert_eq!(std::fs::read_to_string(new.join("sub/a.txt")).unwrap(), "a2", "untouched");
}

/// Leo: "any chat moves Mac↔Cloud and back in one action, keeping its live state". The way
/// back from a machine reached only through the team hub, `--from MACHINE --machine local`,
/// asks that machine as `MACHINE/ID` does instead of needing an ssh peer.
#[test]
fn from_a_hub_machine_names_its_chats_on_that_machine() {
    let mut args = MoveArgs {
        sessions: vec!["01a21a8f".into(), "other-host/abc".into()],
        host: "local".into(),
        all_idle: false,
        interrupt: false,
        after_turn: false,
        turn_timeout: std::time::Duration::from_secs(1),
        slow_ok: false,
        leave_dirty: false,
        carry_changes: false,
        cwd: None,
        dry_run: false,
        resume_there: false,
        from: Some("gcp-agent-lane-19".into()),
        from_snapshot: false,
        as_harness: None,
    };
    from_hub_machine(&mut args, "gcp-agent-lane-19");
    assert_eq!(args.sessions, vec!["gcp-agent-lane-19/01a21a8f", "other-host/abc"]);
    assert_eq!(args.from, None);
}
