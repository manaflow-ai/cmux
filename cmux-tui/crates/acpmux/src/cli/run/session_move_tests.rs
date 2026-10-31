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
    let w = walk(&targets(&["a", "b"]), 0, |_| 0, |t| Err(format!("ssh to {} failed", t.name)));
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
    let w = walk(&targets(&["tight", "roomy"]), 3 * gb, floor, |t| Ok(about_ok(disk(&t.name))));
    assert_eq!(w.pick.unwrap().name, "roomy");
    assert_eq!(w.skipped[0].0, "tight");
    assert!(
        w.skipped[0].1.contains("12.0 GB disk free, under its 10 GB floor plus this move's 3.0 GB"),
        "{:?}",
        w.skipped
    );
    assert!(w.unreachable.is_empty() && w.warning.is_none());

    let w = walk(&targets(&["tighter", "tight"]), 3 * gb, floor, |t| Ok(about_ok(disk(&t.name))));
    assert_eq!(w.pick.unwrap().name, "tight", "most free of the short ones");
    assert!(w.warning.unwrap().contains("disk floors only warn"));

    let w = walk(&targets(&["unread"]), 3 * gb, floor, |t| Ok(about_ok(disk(&t.name))));
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
