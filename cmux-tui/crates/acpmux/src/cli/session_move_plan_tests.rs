use super::*;
use serde_json::json;

fn checkout(top: &str, branch: Option<&str>, dirty: bool) -> Checkout {
    Checkout {
        top: top.into(),
        branch: branch.map(Into::into),
        origin: Some("git@github.com:manaflow-ai/cmux.git".into()),
        dirty,
        default_branch: Some("main".into()),
    }
}

#[test]
fn a_worktree_becomes_a_worktree_of_the_same_branch_with_its_subfolder() {
    let c = checkout("/Users/me/Projects/checkouts/cmux/fix", Some("me/fix"), false);
    let cwd = Path::new("/Users/me/Projects/checkouts/cmux/fix/cmux-tui");
    let f = plan_folder(cwd, Path::new("/Users/me"), Some(&c), "/home/cmux", false, None).unwrap();
    assert_eq!(
        f,
        Folder::Worktree {
            repo: "manaflow-ai/cmux".into(),
            url: "git@github.com:manaflow-ai/cmux.git".into(),
            branch: "me/fix".into(),
            subdir: "cmux-tui".into(),
            dirty: false,
            snapshot: false,
        }
    );
    let top = Path::new("/Users/me/Projects/checkouts/cmux/fix");
    let f = plan_folder(top, Path::new("/Users/me"), Some(&c), "/home/cmux", false, None).unwrap();
    assert!(matches!(f, Folder::Worktree { ref subdir, .. } if subdir.is_empty()), "{f:?}");
}

#[test]
fn a_plain_folder_under_home_maps_to_the_same_path_under_the_targets_home() {
    let home = Path::new("/Users/me");
    for (cwd, want) in [
        ("/Users/me/Projects", "/home/cmux/Projects"),
        ("/Users/me/Projects/scratch/notes", "/home/cmux/Projects/scratch/notes"),
        ("/Users/me", "/home/cmux"),
    ] {
        let f = plan_folder(Path::new(cwd), home, None, "/home/cmux/", false, None).unwrap();
        assert_eq!(f, Folder::Plain { cwd: want.into() }, "{cwd}");
    }
}

#[test]
fn a_folder_outside_home_or_a_relative_target_home_is_refused() {
    let home = Path::new("/Users/me");
    let e =
        plan_folder(Path::new("/tmp/review"), home, None, "/home/cmux", false, None).unwrap_err();
    assert!(e.contains("outside this machine's home"), "{e}");
    let e = plan_folder(Path::new("/Users/me/../x"), home, None, "/home/cmux", false, None)
        .unwrap_err();
    assert!(e.contains("outside"), "{e}");
    let e =
        plan_folder(Path::new("/Users/me/x"), home, None, "home/cmux", false, None).unwrap_err();
    assert!(e.contains("not an absolute path"), "{e}");
}

#[test]
fn a_detached_dirty_or_originless_checkout_is_refused() {
    let home = Path::new("/Users/me");
    let cwd = Path::new("/Users/me/w");
    let e = plan_folder(cwd, home, Some(&checkout("/Users/me/w", None, false)), "/h", false, None);
    assert!(e.unwrap_err().contains("detached HEAD"));
    let dirty = checkout("/Users/me/w", Some("b"), true);
    let e = plan_folder(cwd, home, Some(&dirty), "/h", false, None).unwrap_err();
    assert!(e.contains("uncommitted changes") && e.contains("--leave-dirty"), "{e}");
    let f = plan_folder(cwd, home, Some(&dirty), "/h", true, None).unwrap();
    assert!(matches!(f, Folder::Worktree { dirty: true, .. }), "--leave-dirty moves it: {f:?}");
    let mut none = checkout("/Users/me/w", Some("b"), false);
    none.origin = None;
    assert!(
        plan_folder(cwd, home, Some(&none), "/h", false, None).unwrap_err().contains("no origin")
    );
    let bad = checkout("/Users/me/w", Some("-oProxyCommand=x"), false);
    assert!(
        plan_folder(cwd, home, Some(&bad), "/h", false, None).unwrap_err().contains("plain branch")
    );
}

#[test]
fn repo_slugs_come_from_github_style_urls_only() {
    for (url, want) in [
        ("https://github.com/manaflow-ai/cmux.git", Some("manaflow-ai/cmux")),
        ("https://github.com/manaflow-ai/cmux", Some("manaflow-ai/cmux")),
        ("git@github.com:teamleaderleo/leo-workspace.git", Some("teamleaderleo/leo-workspace")),
        ("ssh://git@github.com/manaflow-ai/cmux.git", Some("manaflow-ai/cmux")),
        ("/srv/git/cmux.git", None),
        ("https://github.com/a/b/c", None),
        ("git@github.com:-x/y", None),
    ] {
        assert_eq!(repo_slug(url).as_deref(), want, "{url}");
    }
}

#[test]
fn a_running_turn_moves_and_a_moving_or_moved_chat_never_moves() {
    let idle = json!({"status": "closed", "turn": null, "moving": false});
    assert_eq!(refusal(&idle, false), None, "a stopped chat moves");
    let running = json!({"status": "running", "turn": {"turnId": "t"}, "moving": false});
    assert_eq!(refusal(&running, true), None, "a running turn moves with the chat");
    // The preflight names it, with every way to move it.
    let why = refusal(&running, false).unwrap();
    assert!(why.contains("--after-turn") && why.contains("--interrupt"), "{why}");
    let moving = json!({"status": "ready", "moving": true});
    assert!(refusal(&moving, true).unwrap().contains("being moved"));
    let moved = json!({"status": "closed", "movedTo": {"host": "gcp-1", "sessionId": "s"}});
    let why = refusal(&moved, true).unwrap();
    assert!(why.contains("moved away already") && why.contains("gcp-1/s"), "{why}");
}

#[test]
fn cwd_names_the_targets_folder_outright_for_any_chat() {
    let home = Path::new("/Users/me");
    // A folder outside the home moves with --cwd, as it is there.
    let f = plan_folder(Path::new("/tmp/review"), home, None, "/home/cmux", false, Some("/srv/x"));
    assert_eq!(f.unwrap(), Folder::Plain { cwd: "/srv/x".into() });
    // A checkout's chat too: no worktree is made, so no branch need be pushed or be clean.
    let dirty = checkout("/Users/me/w", None, true);
    let f = plan_folder(Path::new("/Users/me/w"), home, Some(&dirty), "/h", false, Some("/srv/w"));
    assert_eq!(f.unwrap(), Folder::Plain { cwd: "/srv/w".into() });
    for bad in ["srv/x", "/srv/../x", "/srv/x\n"] {
        let e = plan_folder(Path::new("/tmp/r"), home, None, "/h", false, Some(bad)).unwrap_err();
        assert!(e.contains("--cwd"), "{bad:?}: {e}");
    }
}

/// Item B: a session in a shared checkout on `main` (or origin's HEAD branch) moves as a
/// snapshot of its HEAD, never by pushing that branch; its own branch still moves as before.
#[test]
fn a_shared_default_branch_moves_as_a_snapshot_never_pushed() {
    let home = Path::new("/Users/me");
    let cwd = Path::new("/Users/me/src/cmux");
    for (branch, default, snapshot) in [
        ("main", None, true),
        ("master", None, true),
        ("feat-cmux-next", Some("feat-cmux-next"), true),
        ("main", Some("main"), true),
        ("lane/x", Some("main"), false),
    ] {
        let mut c = checkout("/Users/me/src/cmux", Some(branch), true);
        c.default_branch = default.map(Into::into);
        let f = plan_folder(cwd, home, Some(&c), "/home/cmux", true, None).unwrap();
        assert!(
            matches!(f, Folder::Worktree { snapshot: s, dirty: true, .. } if s == snapshot),
            "{branch} (origin HEAD {default:?}): {f:?}"
        );
    }
}
