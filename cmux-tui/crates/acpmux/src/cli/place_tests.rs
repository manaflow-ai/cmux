use super::*;

#[test]
fn host_place_prints_the_pick_then_each_hosts_room_or_refusal() {
    let v = json!({"pick": "big", "why": "big: 60 GB RAM free, room for 13", "hosts": [
        {"name": "laptop", "local": true, "refused": "no builds here (lanes.build is false)",
         "why": "14 GB RAM free, room for 3"},
        {"name": "big", "local": false, "refused": null, "why": "60 GB RAM free, room for 13"},
        {"name": "mini", "local": false, "refused": "not a lane host", "why": ""},
    ]});
    assert_eq!(
        lines(&v),
        [
            "pick big: 60 GB RAM free, room for 13",
            "  laptop (this)        refused  no builds here (lanes.build is false) (14 GB RAM free, room for 3)",
            "  big                  ok       60 GB RAM free, room for 13",
            "  mini                 refused  not a lane host",
        ]
    );
    assert_eq!(auto_work(Some("auto")), Some("agent"));
    assert_eq!(auto_work(Some("auto-build")), Some("build"));
    assert_eq!(auto_work(Some("huge-blue")), None);
}

/// On a machine a person works at, a command-line `new` with no `--host` is placed on a
/// fleet host; `--host local` and a named host are kept; elsewhere nothing changes.
#[test]
fn a_new_from_an_interactive_machine_is_placed_unless_a_host_is_named() {
    assert_eq!(new_target(None, true, false), Target::Place("agent"));
    assert_eq!(new_target(None, true, true), Target::HereForFolder);
    for folder in [true, false] {
        assert_eq!(new_target(None, false, folder), Target::Here);
        for interactive in [true, false] {
            let t = |h| new_target(Some(h), interactive, folder);
            assert_eq!(t("local"), Target::Here);
            assert_eq!(t("auto"), Target::Place("agent"));
            assert_eq!(t("auto-build"), Target::Place("build"));
            assert_eq!(t("box"), Target::Host("box".into()));
        }
    }
    let none = json!({"pick": null, "why": "no host has room for this"});
    // An explicit `--host auto` still stops; only a `new` that named no host starts here,
    // and not on a held machine.
    let e = without_pick(&none, false, None).unwrap_err().to_string();
    assert_eq!(e, "no host has room for this");
    assert_eq!(without_pick(&none, true, None).unwrap(), None);
    let e = without_pick(&none, true, Some("reserved for sam until x (r)".into()));
    assert!(e.unwrap_err().to_string().ends_with("this machine is reserved for sam until x (r)"));
    assert_eq!(
        no_fleet_host(&none),
        "starting on this machine: no fleet host took it (no host has room for this); \
             `acpmux machine add` connects one"
    );
}

#[test]
fn a_running_name_is_found_on_each_machine_that_runs_it() {
    let list = json!({"sessions": [
        {"name": "lane"},
        {"name": "b/lane", "peer": "b"},
        {"name": "c/lane", "peer": "c"},
        {"name": "c/lane", "peer": "c"},
        {"name": "b/other", "peer": "b"},
        {"name": "lane-2"},
    ]});
    assert_eq!(running_on(&list, "lane"), [None, Some("b".into()), Some("c".into())]);
    assert_eq!(running_on(&list, "other"), [Some("b".to_owned())]);
    assert!(running_on(&list, "b").is_empty(), "a peer's name is not a session name");
    assert!(running_on(&list, "fresh").is_empty());
}
