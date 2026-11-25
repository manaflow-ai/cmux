use super::*;

#[test]
fn a_hub_move_names_its_folder_as_the_target_can_make_it() {
    let home = Path::new("/home/me");
    let plain = Folder::Plain { cwd: "/home/me/notes/a".into() };
    assert_eq!(folder_value(&plain, home, false).unwrap(), json!({"home": "notes/a"}));
    assert_eq!(folder_value(&plain, home, true).unwrap(), json!({"cwd": "/home/me/notes/a"}));
    let outside = Folder::Plain { cwd: "/srv/x".into() };
    assert!(folder_value(&outside, home, false).is_err());
    let tree = Folder::Worktree {
        repo: "o/n".into(),
        url: "https://github.com/o/n.git".into(),
        branch: "lane/x".into(),
        subdir: "sub".into(),
        dirty: false,
        snapshot: false,
    };
    assert_eq!(
        folder_value(&tree, home, false).unwrap(),
        json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": "sub"})
    );
}
