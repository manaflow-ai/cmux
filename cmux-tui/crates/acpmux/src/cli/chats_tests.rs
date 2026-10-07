use super::*;
use clap::Parser;

#[derive(Parser)]
struct Wrap {
    #[command(subcommand)]
    cmd: ChatsCmd,
}

fn parse(words: &[&str]) -> ChatsCmd {
    let mut argv = vec!["chats"];
    argv.extend_from_slice(words);
    Wrap::try_parse_from(argv).map(|w| w.cmd).unwrap_or_else(|e| panic!("{e}"))
}

#[test]
fn list_parses_every_filter_and_defaults_the_limit() {
    assert_eq!(
        parse(&["list"]),
        ChatsCmd::List { harness: None, folder: None, account: None, query: None, limit: 50 }
    );
    assert_eq!(
        parse(&[
            "ls",
            "--harness",
            "codex",
            "--folder",
            "/r",
            "--account",
            "a1",
            "-q",
            "fix",
            "-n",
            "5"
        ]),
        ChatsCmd::List {
            harness: Some("codex".into()),
            folder: Some("/r".into()),
            account: Some("a1".into()),
            query: Some("fix".into()),
            limit: 5,
        }
    );
}

#[test]
fn open_and_roots_parse() {
    assert_eq!(
        parse(&["open", "codex:abc"]),
        ChatsCmd::Open { key: "codex:abc".into(), cwd: None }
    );
    assert_eq!(
        parse(&["open", "codex:abc", "--cwd", "/repo"]),
        ChatsCmd::Open { key: "codex:abc".into(), cwd: Some(PathBuf::from("/repo")) }
    );
    assert_eq!(parse(&["roots"]), ChatsCmd::Roots);
    assert!(Wrap::try_parse_from(["chats", "open"]).is_err());
}

#[test]
fn list_params_drop_empty_filters_and_keep_a_positive_limit() {
    assert_eq!(list_params(None, None, None, None, 50), json!({"limit": 50}));
    assert_eq!(
        list_params(Some("pi"), Some(""), Some("a"), Some("x"), 0),
        json!({"limit": 1, "harness": "pi", "account": "a", "query": "x"})
    );
}

#[test]
fn open_params_need_a_chat_key_and_an_absolute_folder() {
    assert_eq!(open_params("codex:abc", None).unwrap(), json!({"key": "codex:abc"}));
    assert_eq!(
        open_params("claude-code:x1", Some(Path::new("/repo"))).unwrap(),
        json!({"key": "claude-code:x1", "cwd": "/repo"})
    );
    assert_eq!(open_params("nokey", None).unwrap_err().code, Code::Usage);
    assert_eq!(open_params("codex:abc", Some(Path::new("rel"))).unwrap_err().code, Code::Usage);
}

#[test]
fn a_plan_that_needs_a_folder_is_a_usage_error_with_the_reason() {
    let plan = json!({"key": "codex:a", "kind": "terminal", "cwd": null,
        "needsFolder": {"reason": "the chat recorded no folder; pick one"},
        "terminal": {"argv": ["codex", "resume", "a"], "env": {}}});
    let error = read_plan(&plan).unwrap_err();
    assert_eq!(error.code, Code::Usage);
    assert!(error.message.contains("recorded no folder"), "{}", error.message);
    assert!(error.message.contains("--cwd"), "{}", error.message);
}

#[test]
fn plans_read_into_outcomes() {
    let adopt = json!({"key": "codex:a", "kind": "adopt", "cwd": "/r", "needsFolder": null,
        "adopt": {"harness": "codex", "agentSessionId": "a"},
        "sessionNew": {"cwd": "/r", "mcpServers": []}});
    assert_eq!(
        read_plan(&adopt).unwrap(),
        Planned::Adopt { session_new: json!({"cwd": "/r", "mcpServers": []}) }
    );
    let terminal = json!({"key": "claude-code:a", "kind": "terminal", "cwd": "/r", "needsFolder": null,
        "terminal": {"argv": ["claude", "--resume", "a"], "env": {"CLAUDE_CONFIG_DIR": "/h/acct"}}});
    assert_eq!(
        read_plan(&terminal).unwrap(),
        Planned::Ready(OpenOutcome::Terminal {
            argv: vec!["claude".into(), "--resume".into(), "a".into()],
            env: BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), "/h/acct".to_owned())]),
            cwd: PathBuf::from("/r"),
        })
    );
    let read_only = json!({"key": "amp:T-1", "kind": "readOnly", "cwd": "/r", "needsFolder": null,
        "readOnly": {"path": "/h/.local/share/amp/threads/T-1.json"}});
    assert_eq!(
        read_plan(&read_only).unwrap(),
        Planned::Ready(OpenOutcome::ReadOnly {
            path: PathBuf::from("/h/.local/share/amp/threads/T-1.json")
        })
    );
    let empty = json!({"key": "x:a", "kind": "terminal", "cwd": "/r", "terminal": {"argv": []}});
    assert_eq!(read_plan(&empty).unwrap_err().code, Code::Runtime);
    assert!(read_plan(&json!({"kind": "teleport"})).is_err());
}

#[test]
fn the_list_table_is_one_line_per_chat_with_control_characters_removed() {
    let page = json!({"ready": true, "nextCursor": null, "chats": [
        {"key": "codex:a", "harness": "codex", "updatedMs": 1_000_000 - 120_000,
         "title": "fix\nthe \u{1b}[31mbug", "cwd": "/repo"},
        {"key": "pi:b", "harness": "pi", "updatedMs": 1_000_000 - 3_600_000 * 30, "title": null}
    ]});
    let text = list_text(&page, 1_000_000);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(lines[0].starts_with("codex:a  codex"), "{text}");
    assert!(lines[0].contains("2m  fix the  [31mbug  /repo"), "{text}");
    assert!(!text.contains('\u{1b}'));
    assert!(lines[1].contains("1d  (untitled)"), "{text}");
}

#[test]
fn the_list_table_says_when_chats_are_off_or_scanning() {
    let off = json!({"ready": true, "enabled": false, "chats": []});
    assert!(list_text(&off, 0).contains("turned off"));
    let scanning = json!({"ready": false, "chats": []});
    let text = list_text(&scanning, 0);
    assert!(text.contains("still scanning") && text.contains("no chats"), "{text}");
}

#[test]
fn the_roots_text_lists_refused_roots_with_their_reason() {
    let view = json!({
        "roots": [{"harness": "claude-code", "path": "/h/.claude/projects", "source": "default", "accounts": ["work"]}],
        "refused": [{"harness": "codex", "path": "/h/Documents/x", "source": "user", "reason": "inside Documents"}],
        "settingsRefused": [{"path": "/h", "reason": "the home folder itself"}],
        "watchErrors": []
    });
    let text = roots_text(&view);
    assert!(text.contains("claude-code  /h/.claude/projects  [default]  (work)"), "{text}");
    assert!(text.contains("/h/Documents/x: inside Documents"), "{text}");
    assert!(text.contains("/h: the home folder itself"), "{text}");
}
