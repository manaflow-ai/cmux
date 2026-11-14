use super::*;

fn placement(group: &str, index: u64, workspace: Option<&str>, key: &str) -> Value {
    json!({"group_id": group, "index": index,
               "workspace": {"workspace_id": workspace, "workspace_ref": key, "session_id": "s"}})
}

fn groups() -> Value {
    json!([
        {"id": "grp_l1", "name": "Leads", "room_id": "default", "index": 0, "pinned": false},
        {"id": "grp_t1", "name": "UI think tank", "room_id": "default", "index": 1, "pinned": false},
        {"id": "grp_l2", "name": " Leads", "room_id": "default", "index": 2, "pinned": false},
        {"id": "grp_t2", "name": "UI think tank", "room_id": "default", "index": 3, "pinned": false},
        {"id": "grp_l3", "name": "Leads", "room_id": "side", "index": 4, "pinned": false},
        {"id": "grp_lc", "name": "leads", "room_id": "default", "index": 5, "pinned": false},
        {"id": "grp_solo", "name": "Empty and mine", "room_id": "default", "index": 6, "pinned": false},
    ])
}

#[test]
fn tidy_merges_each_duplicate_into_the_first_of_its_name_in_its_space() {
    let placements = [
        placement("grp_l1", 0, Some("ws_a"), "ka"),
        placement("grp_l2", 2, Some("ws_c"), "kc"),
        placement("grp_l2", 1, Some("ws_b"), "kb"),
    ];
    let plan = tidy_plan(&groups(), &placements);
    assert_eq!(
        plan,
        [
            Merge {
                name: "Leads".into(),
                room: "default".into(),
                from: "grp_l2".into(),
                into: "grp_l1".into(),
                members: vec!["ws_b".into(), "ws_c".into()],
                unmovable: 0,
            },
            Merge {
                name: "UI think tank".into(),
                room: "default".into(),
                from: "grp_t2".into(),
                into: "grp_t1".into(),
                members: vec![],
                unmovable: 0,
            },
        ],
        "another space's Leads, a lowercase leads and a group of its own name stay"
    );
}

#[test]
fn tidy_keeps_a_pinned_group_and_leaves_another_machines_members() {
    let groups = json!([
        {"id": "grp_a", "name": "Leads", "room_id": "default", "index": 0, "pinned": false},
        {"id": "grp_b", "name": "Leads", "room_id": "default", "index": 1, "pinned": true},
    ]);
    let placements =
        [placement("grp_a", 0, Some("ws_a"), "ka"), placement("grp_a", 1, None, "remote")];
    let plan = tidy_plan(&groups, &placements);
    assert_eq!(plan.len(), 1);
    assert_eq!((plan[0].from.as_str(), plan[0].into.as_str()), ("grp_a", "grp_b"));
    assert_eq!(plan[0].members, ["ws_a"]);
    assert_eq!(plan[0].unmovable, 1, "the duplicate keeps another machine's row, so it stays");
}

#[test]
fn ls_marks_duplicates_per_space() {
    let listed = list(&groups(), &[placement("grp_l1", 0, Some("ws_a"), "ka")]);
    let dup: Vec<(&str, bool)> = listed
        .iter()
        .map(|group| (group["id"].as_str().unwrap(), group["duplicate"] == true))
        .collect();
    assert_eq!(
        dup,
        [
            ("grp_l1", true),
            ("grp_t1", true),
            ("grp_l2", true),
            ("grp_t2", true),
            ("grp_l3", false),
            ("grp_lc", false),
            ("grp_solo", false),
        ]
    );
    assert_eq!(listed[0]["members"], json!(["ws_a"]));
}

#[test]
fn move_finds_the_workspace_acpmux_opened_for_the_session() {
    let key = crate::cli::run::launch::workspace_key("peer/abc");
    let placements =
        [placement("grp_x", 0, Some("ws_other"), "k"), placement("", 1, Some("ws_mine"), &key)];
    assert_eq!(workspace_of(&placements, &key).as_deref(), Some("ws_mine"));
    assert_eq!(workspace_of(&placements, "missing"), None);
}
