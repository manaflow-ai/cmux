//! The Swift cases of `TerminalLaunchTests`, `imageTypeIsReadFromItsBytes` and
//! `pickingAgentsKeepsOneAndStopsAtTheLimit`, ported, and more.

use super::*;

fn launch(prompt: &str, family: &str) -> TaskTerminalLaunch {
    TaskTerminalLaunch { prompt: prompt.into(), family: Some(family.into()), ..Default::default() }
}

fn line(launch: TaskTerminalLaunch) -> String {
    task_terminal_line(launch).expect("a known CLI")
}

#[test]
fn claude_and_codex_get_their_commands() {
    let sonnet = TaskTerminalLaunch { model: Some("sonnet".into()), ..launch("Fix it", "claude") };
    assert_eq!(line(sonnet), "claude --model=$'sonnet' -- $'Fix it'\n");
    assert_eq!(line(launch("Fix it", "codex")), "codex -- $'Fix it'\n");
    let default = TaskTerminalLaunch { model: Some("default".into()), ..launch("Fix it", "claude") };
    assert_eq!(line(default), "claude -- $'Fix it'\n");
    let empty = TaskTerminalLaunch { model: Some(String::new()), ..launch("Fix it", "codex") };
    assert_eq!(line(empty), "codex -- $'Fix it'\n");
}

#[test]
fn an_agent_with_no_known_cli_gets_no_line() {
    assert_eq!(task_terminal_line(launch("Fix it", "opencode")), None);
    assert_eq!(
        task_terminal_line(TaskTerminalLaunch { prompt: "Fix it".into(), ..Default::default() }),
        None
    );
}

#[test]
fn mode_and_effort_go_as_each_clis_own_flags() {
    let claude = TaskTerminalLaunch {
        model: Some("opus".into()),
        effort: Some("high".into()),
        mode: Some("plan".into()),
        ..launch("Fix it", "claude")
    };
    assert_eq!(
        line(claude),
        "claude --model=$'opus' --effort=$'high' --permission-mode=$'plan' -- $'Fix it'\n"
    );
    let codex = TaskTerminalLaunch { effort: Some("high".into()), ..launch("Fix it", "codex") };
    assert_eq!(line(codex), "codex -c $'model_reasoning_effort=high' -- $'Fix it'\n");
    // Codex has no permission mode flag: a mode is not sent.
    let codex_mode = TaskTerminalLaunch { mode: Some("plan".into()), ..launch("Fix it", "codex") };
    assert_eq!(line(codex_mode), "codex -- $'Fix it'\n");
    let quoted = TaskTerminalLaunch { mode: Some("pl'an; rm".into()), ..launch("x", "claude") };
    assert_eq!(line(quoted), "claude --permission-mode=$'pl\\'an; rm' -- $'x'\n");
}

#[test]
fn the_prompt_is_one_quoted_word_whatever_it_holds() {
    let got = line(launch("it's `rm -rf ~` $(whoami)\\\nnext\u{1b}[2J\u{7}line", "claude"));
    assert_eq!(got, "claude -- $'it\\'s `rm -rf ~` $(whoami)\\\\\\nnext[2Jline'\n");
    assert_eq!(got.matches('\n').count(), 1);
    // Tabs are escaped; DEL, C1 controls and bidi overrides are dropped.
    let got = line(launch("a\tb\u{7f}c\u{85}d\u{202E}e\u{2066}f\u{2069}g\r", "codex"));
    assert_eq!(got, "codex -- $'a\\tbcdefg'\n");
}

#[test]
fn attached_files_are_named_after_the_prompt() {
    let task =
        TaskTerminalLaunch { attachment_paths: vec!["/p/a.png".into()], ..launch("Match this", "claude") };
    assert_eq!(line(task), "claude -- $'Match this\\n\\nAttached files (read them):\\n/p/a.png'\n");
    let two = TaskTerminalLaunch {
        attachment_paths: vec!["/p/a.png".into(), "/p/b.txt".into()],
        ..launch("Read", "codex")
    };
    assert_eq!(line(two), "codex -- $'Read\\n\\nAttached files (read them):\\n/p/a.png\\n/p/b.txt'\n");
}

#[test]
fn options_and_scripts_are_safe() {
    let task = TaskTerminalLaunch { model: Some("-x'y".into()), ..launch("--help me", "claude") };
    assert_eq!(line(task), "claude --model=$'-x\\'y' -- $'--help me'\n");
    // The joiners Persian and emoji need stay; the override hiding "evil" goes.
    let persian = "می\u{200C}خواهم 👩\u{200D}💻 \u{202E}evil";
    assert_eq!(line(launch(persian, "codex")), "codex -- $'می\u{200C}خواهم 👩\u{200D}💻 evil'\n");
}

#[test]
fn the_agent_runs_in_the_folder_or_not_at_all() {
    let at =
        |folder: &str| line(TaskTerminalLaunch { folder: Some(folder.into()), ..launch("Go", "claude") });
    assert_eq!(at("/Users/me/my repo"), "cd -- $'/Users/me/my repo' && claude -- $'Go'\n");
    assert_eq!(at("~/code/a\\b"), "cd -- ~/$'code/a\\\\b' && claude -- $'Go'\n");
    assert_eq!(at("~"), "cd -- ~ && claude -- $'Go'\n");
    // `~user` is not the person's home: quoted, never expanded.
    assert_eq!(at("~root/x"), "cd -- $'~root/x' && claude -- $'Go'\n");
    assert_eq!(at("/a'; rm -rf /"), "cd -- $'/a\\'; rm -rf /' && claude -- $'Go'\n");
}

#[test]
fn image_type_is_read_from_its_bytes() {
    let padded = |head: &[u8]| {
        let mut bytes = head.to_vec();
        bytes.resize(12, 0);
        task_image_mime_type(bytes)
    };
    assert_eq!(padded(&[0x89, 0x50, 0x4E, 0x47]).as_deref(), Some("image/png"));
    assert_eq!(padded(&[0xFF, 0xD8, 0xFF]).as_deref(), Some("image/jpeg"));
    assert_eq!(padded(b"GIF89a").as_deref(), Some("image/gif"));
    assert_eq!(task_image_mime_type(b"RIFF\0\0\0\0WEBP".to_vec()).as_deref(), Some("image/webp"));
    assert_eq!(task_image_mime_type(b"RIFF\0\0\0\0WAVE".to_vec()), None);
    assert_eq!(task_image_mime_type(b"ftypheic0000".to_vec()), None);
    // Fewer than 12 bytes is no image, whatever they start with.
    assert_eq!(task_image_mime_type(vec![0x89, 0x50, 0x4E, 0x47]), None);
    assert_eq!(task_image_mime_type(Vec::new()), None);
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn picking_agents_keeps_one_and_stops_at_the_limit() {
    // No pick: the shown default becomes a real pick, then the tapped agent joins it.
    let first = task_pick_toggle(vec![], "router".into(), true, Some("claude".into()), 4);
    assert_eq!(first, TaskPickToggle { change: TaskPickChange::Added, picks: ids(&["claude", "router"]) });
    // Tapping the shown default with no pick keeps it as the one pick.
    let same = task_pick_toggle(vec![], "claude".into(), true, Some("claude".into()), 4);
    assert_eq!(same, TaskPickToggle { change: TaskPickChange::KeptLast, picks: ids(&["claude"]) });
    let removed = task_pick_toggle(ids(&["claude", "router"]), "claude".into(), true, None, 4);
    assert_eq!(removed, TaskPickToggle { change: TaskPickChange::Removed, picks: ids(&["router"]) });
    let last = task_pick_toggle(ids(&["router"]), "router".into(), true, None, 4);
    assert_eq!(last.change, TaskPickChange::KeptLast);
    let full = task_pick_toggle(ids(&["a", "b", "c", "d"]), "e".into(), true, None, 4);
    assert_eq!(full, TaskPickToggle { change: TaskPickChange::AtLimit, picks: ids(&["a", "b", "c", "d"]) });
    // At the limit, a chosen agent still comes off.
    let off = task_pick_toggle(ids(&["a", "b", "c", "d"]), "b".into(), true, None, 4);
    assert_eq!(off, TaskPickToggle { change: TaskPickChange::Removed, picks: ids(&["a", "c", "d"]) });
}

#[test]
fn an_agent_the_phone_cant_start_changes_nothing() {
    let none = task_pick_toggle(vec![], "gemini".into(), false, Some("claude".into()), 4);
    assert_eq!(none, TaskPickToggle { change: TaskPickChange::Unavailable, picks: vec![] });
    let some = task_pick_toggle(ids(&["claude"]), "claude".into(), false, None, 4);
    assert_eq!(some, TaskPickToggle { change: TaskPickChange::Unavailable, picks: ids(&["claude"]) });
}

#[test]
fn no_fallback_and_no_pick_adds_the_tapped_agent() {
    let got = task_pick_toggle(vec![], "codex".into(), true, None, 4);
    assert_eq!(got, TaskPickToggle { change: TaskPickChange::Added, picks: ids(&["codex"]) });
}
