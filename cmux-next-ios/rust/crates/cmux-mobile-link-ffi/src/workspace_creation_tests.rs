use super::*;

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

fn choices(directories: bool, agents: &[&str]) -> WorkspaceCreationChoices {
    WorkspaceCreationChoices {
        directories,
        agents: strings(agents),
        browser: false,
        tap_uses_last_directory: true,
    }
}

#[test]
fn a_noted_folder_goes_first_once_and_the_list_keeps_five() {
    assert_eq!(workspace_recents_noted(vec![], "~/a".into()), strings(&["~/a"]));
    assert_eq!(
        workspace_recents_noted(strings(&["~/b", "~/a", "~/c"]), "~/a".into()),
        strings(&["~/a", "~/b", "~/c"])
    );
    let full = strings(&["1", "2", "3", "4", "5"]);
    assert_eq!(workspace_recents_noted(full.clone(), "6".into()), strings(&["6", "1", "2", "3", "4"]));
    assert_eq!(workspace_recents_noted(full, "5".into()), strings(&["5", "1", "2", "3", "4"]));
}

#[test]
fn recent_directories_put_this_phones_first_then_the_macs_without_repeats() {
    assert!(workspace_recent_directories(false, strings(&["~/a"]), strings(&["~/b"])).is_empty());
    assert_eq!(
        workspace_recent_directories(true, strings(&["~/a", "~/b"]), strings(&["~/b", "~/c"])),
        strings(&["~/a", "~/b", "~/c"])
    );
    let seen = strings(&["1", "2", "3", "4", "5", "6"]);
    assert_eq!(workspace_recent_directories(true, strings(&["0"]), seen).len(), RECENT_LIMIT);
}

#[test]
fn a_tap_opens_the_default_agent_in_the_newest_open_project_folder() {
    let tap = workspace_tap_start(
        choices(true, &["claude", ""]),
        strings(&["~/gone", "~"]),
        strings(&["~", "~/cmux", "~/web"]),
    );
    assert_eq!(
        tap,
        WorkspaceTap {
            start: WorkspaceStart::Agent { harness: String::new() },
            directory: Some("~/cmux".into())
        }
    );
    // No default agent: the first one the Mac offers.
    let tap = workspace_tap_start(choices(true, &["codex", "claude"]), vec![], strings(&["~/web"]));
    assert_eq!(tap.start, WorkspaceStart::Agent { harness: "codex".into() });
    // This phone's folder wins over the Mac's newest, when it is open.
    let tap = workspace_tap_start(choices(true, &[""]), strings(&["~/web"]), strings(&["~/cmux", "~/web"]));
    assert_eq!(tap.directory.as_deref(), Some("~/web"));
}

#[test]
fn a_tap_makes_a_terminal_without_an_agent_a_folder_choice_or_an_open_project_folder() {
    let terminal = WorkspaceTap { start: WorkspaceStart::Terminal, directory: None };
    assert_eq!(workspace_tap_start(choices(true, &[]), vec![], strings(&["~/cmux"])), terminal);
    assert_eq!(workspace_tap_start(choices(false, &[""]), vec![], strings(&["~/cmux"])), terminal);
    assert_eq!(
        workspace_tap_start(choices(true, &[""]), strings(&["~/closed"]), strings(&["~", "/Users/lawrence"])),
        terminal
    );
}

#[test]
fn project_folders_are_not_home_or_above_it() {
    for home in
        ["", "  ", "~", "~/", "/", "//", "/Users", "/Users/leo", "/Users/leo/", "/var", "/var/root", " ~ "]
    {
        assert!(!workspace_is_project_folder(home.into()), "{home:?}");
    }
    for project in ["~/cmux", "/Users/Shared", "/Users/leo/cmux", "/tmp", "/var/tmp", "cmux", "/opt/x"] {
        assert!(workspace_is_project_folder(project.into()), "{project:?}");
    }
}

#[test]
fn the_default_directory_is_the_last_used_else_home_unless_the_mac_picks() {
    assert_eq!(workspace_default_directory(choices(true, &[]), vec![]).as_deref(), Some("~"));
    assert_eq!(
        workspace_default_directory(choices(true, &[]), strings(&["~/a", "~/b"])).as_deref(),
        Some("~/a")
    );
    assert_eq!(workspace_default_directory(choices(false, &[]), strings(&["~/a"])), None);
    let mut mac_default = choices(true, &[]);
    mac_default.tap_uses_last_directory = false;
    assert_eq!(workspace_default_directory(mac_default, strings(&["~/a"])), None);
}

#[test]
fn a_start_is_offered_only_when_the_mac_has_it() {
    let mut mac = choices(true, &["claude"]);
    assert!(workspace_start_offered(mac.clone(), WorkspaceStart::Terminal));
    assert!(workspace_start_offered(mac.clone(), WorkspaceStart::Agent { harness: "claude".into() }));
    assert!(!workspace_start_offered(mac.clone(), WorkspaceStart::Agent { harness: String::new() }));
    assert!(!workspace_start_offered(mac.clone(), WorkspaceStart::Browser));
    mac.browser = true;
    assert!(workspace_start_offered(mac, WorkspaceStart::Browser));
}

#[test]
fn placeholder_titles_name_the_folder_and_stay_unique() {
    assert_eq!(workspace_placeholder_title(None, vec![]), "New Workspace");
    assert_eq!(workspace_placeholder_title(Some("~".into()), vec![]), "New Workspace");
    assert_eq!(workspace_placeholder_title(Some("/".into()), vec![]), "New Workspace");
    assert_eq!(workspace_placeholder_title(Some("~/Development/cmux".into()), vec![]), "cmux");
    assert_eq!(workspace_placeholder_title(Some("~/Development/cmux/".into()), vec![]), "cmux");
    assert_eq!(workspace_placeholder_title(Some("cmux".into()), vec![]), "cmux");
    assert_eq!(workspace_placeholder_title(Some("~/cmux".into()), strings(&["cmux", "cmux 2"])), "cmux 3");
    assert_eq!(workspace_unique_title("New Workspace".into(), vec![]), "New Workspace");
    assert_eq!(
        workspace_unique_title("New Workspace".into(), strings(&["New Workspace", "New Workspace 2"])),
        "New Workspace 3"
    );
}

#[test]
fn agent_tab_titles() {
    assert_eq!(workspace_agent_tab_title(String::new()), "Agent Chat");
    assert_eq!(workspace_agent_tab_title("claude".into()), "Claude");
    assert_eq!(workspace_agent_tab_title("codex".into()), "Codex");
    assert_eq!(workspace_agent_tab_title("opencode".into()), "Opencode");
    assert_eq!(workspace_agent_tab_title("gemini-CLI".into()), "Gemini-Cli");
}

fn index(slot: NewTabSlot, from: u32, anchor: u32, pinned: &[bool], groups: &[Option<&str>]) -> Option<u32> {
    new_tab_move_index(
        slot,
        from,
        anchor,
        pinned.to_vec(),
        groups.iter().map(|g| g.map(str::to_owned)).collect(),
    )
}

#[test]
fn new_tab_slots_match_the_macs_new_tab_slot() {
    // One pinned tab, then four; the new tab is the last.
    let pinned = [true, false, false, false, false];
    assert_eq!(index(NewTabSlot::SameKind, 4, 1, &pinned, &[]), Some(2));
    assert_eq!(index(NewTabSlot::AfterCurrent, 4, 1, &pinned, &[]), Some(2));
    assert_eq!(index(NewTabSlot::AfterCurrent, 4, 3, &pinned, &[]), None);
    assert_eq!(index(NewTabSlot::Start, 4, 2, &pinned, &[]), Some(1));
    assert_eq!(index(NewTabSlot::End, 4, 2, &pinned, &[]), None);
    let six = [true, false, false, false, false, false];
    // A forward move counts one past.
    assert_eq!(index(NewTabSlot::End, 2, 1, &six, &[]), Some(6));
    // After the anchor goes past its whole group.
    let groups = [None, Some("g"), Some("g"), None, None];
    assert_eq!(index(NewTabSlot::AfterCurrent, 4, 1, &pinned, &groups), Some(3));
    // Never among pinned tabs.
    assert_eq!(index(NewTabSlot::AfterCurrent, 4, 0, &[true, true, false, false, false], &[]), Some(2));
}

#[test]
fn new_tab_slots_refuse_degenerate_panes() {
    assert_eq!(index(NewTabSlot::End, 0, 0, &[false], &[]), None);
    assert_eq!(index(NewTabSlot::End, 0, 0, &[false, false], &[]), None);
    assert_eq!(index(NewTabSlot::End, 5, 0, &[false, false], &[]), None);
    assert_eq!(index(NewTabSlot::End, 0, 9, &[false, false], &[]), None);
    assert_eq!(index(NewTabSlot::End, 0, 1, &[], &[]), None);
    // Short group lists are read as no group past their end.
    assert_eq!(index(NewTabSlot::AfterCurrent, 3, 0, &[false, false, false, false], &[Some("g")]), Some(1));
}

#[test]
fn a_pane_of_a_thousand_tabs_is_linear() {
    let pinned = vec![false; 1000];
    let groups: Vec<Option<String>> = (0..1000).map(|_| Some("g".to_owned())).collect();
    assert_eq!(new_tab_move_index(NewTabSlot::AfterCurrent, 999, 0, pinned, groups), None);
}
