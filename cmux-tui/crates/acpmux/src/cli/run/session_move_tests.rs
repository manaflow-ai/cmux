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
