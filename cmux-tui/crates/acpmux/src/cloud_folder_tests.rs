use super::*;

const TABLE: &str = "22 1 8:1 / / rw,relatime - ext4 /dev/vda1 rw\n\
        40 22 0:41 / /home/cmux/work/empty\\040folder rw,nosuid,nodev - fuse.cmux cmux-projection:/Users/p/Desktop/empty%20folder rw,user_id=1000\n\
        41 22 0:42 / /home/cmux/work/old rw,nosuid,nodev - fuse.cmux cmux-projection rw,user_id=1000\n\
        42 22 0:43 / /home/cmux/work/other rw,nosuid,nodev - fuse.sshfs host:/x rw\n";

#[test]
fn an_empty_projected_folder_names_its_mac_folder_and_how_edits_come_back() {
    let path = Path::new("/home/cmux/work/empty folder");
    let answer = describe_with(path, TABLE, None);
    assert_eq!(answer["projected"], true);
    assert_eq!(answer["mac_folder"], "/Users/p/Desktop/empty folder");
    assert_eq!(answer["edits_reach_mac"], "on_bring_back");
    assert_eq!(answer["git"], false);
    let summary = answer["summary"].as_str().unwrap();
    assert!(summary.contains("/Users/p/Desktop/empty folder"), "{summary}");
    assert!(
        summary.contains("Bring Back") && summary.contains("not a git repository"),
        "{summary}"
    );
    assert!(!summary.contains("nothing here is copied"), "{summary}");
}

#[test]
fn a_folder_below_a_projection_is_in_it_and_an_old_mount_has_no_mac_name() {
    let below = describe_with(Path::new("/home/cmux/work/empty folder/src"), TABLE, None);
    assert_eq!(below["projected"], true);
    assert_eq!(below["mount_point"], "/home/cmux/work/empty folder");
    let old =
        describe_with(Path::new("/home/cmux/work/old"), TABLE, Some("/home/cmux/work/old".into()));
    assert_eq!(old["projected"], true);
    assert_eq!(old["mac_folder"], Value::Null);
    assert!(old["summary"].as_str().unwrap().contains("a git repository"));
}

#[test]
fn a_projected_git_folder_says_so_and_still_comes_back_on_bring_back() {
    let path = Path::new("/home/cmux/work/empty folder");
    let answer = describe_with(path, TABLE, Some(path.into()));
    assert_eq!(answer["projected"], true);
    assert_eq!(answer["git"], true);
    let summary = answer["summary"].as_str().unwrap();
    assert!(summary.contains("is a git repository") && summary.contains("Bring Back"), "{summary}");
}

#[test]
fn a_folder_of_clones_names_each_as_the_persons_own_checkout_never_stale() {
    let path = Path::new("/home/cmux/work/empty folder");
    let projection = projection_of(path, TABLE);
    let found = [
        Checkout {
            path: path.join("cmux-pr-20415"),
            branch: Some("issue-19225".into()),
            date: Some("2026-10-19".into()),
            commit: Some("3a7d41ecf4f".into()),
        },
        Checkout { path: path.join("fresh"), branch: None, date: None, commit: None },
    ];
    let answer = describe_found(path, projection, None, &found);
    let summary = answer["summary"].as_str().unwrap();
    assert!(
        summary
            .contains("cmux-pr-20415 on branch issue-19225, last commit 3a7d41ecf4f of 2026-10-19"),
        "{summary}"
    );
    assert!(summary.contains("fresh on detached HEAD, no commit yet"), "{summary}");
    assert!(summary.contains("exactly as it is on their Mac now"), "{summary}");
    assert!(summary.contains("instead of cloning it again"), "{summary}");
    assert_eq!(answer["repositories"][0]["commit_date"], "2026-10-19");
    assert_eq!(answer["repositories"][0]["mac_checkout"], true);
    // The machine's own folder lists none: its repositories are not the Mac's.
    let own = describe_found(Path::new("/home/cmux/work/plain"), None, None, &found);
    assert!(own.get("repositories").is_none());
    assert!(!own["summary"].as_str().unwrap().contains("checkout"));
}

#[test]
fn checkouts_finds_clones_below_and_reads_their_branch_and_date() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let run = |at: &Path, args: &[&str]| {
        let ok = std::process::Command::new("git")
            .arg("-C")
            .arg(at)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_COMMITTER_DATE", "2026-10-19T12:00:00Z")
            .env("GIT_AUTHOR_DATE", "2026-10-19T12:00:00Z")
            .status()
            .unwrap();
        assert!(ok.success(), "git {args:?}");
    };
    for clone in ["a-clone", "deep/x/b-clone"] {
        let at = root.join(clone);
        std::fs::create_dir_all(&at).unwrap();
        run(&at, &["init", "-q", "-b", "issue-19225"]);
        run(&at, &["commit", "-q", "--allow-empty", "-m", "old"]);
    }
    std::fs::create_dir_all(root.join("a-clone/sub/.git")).unwrap();
    std::fs::create_dir_all(root.join("node_modules/p/.git")).unwrap();
    std::fs::create_dir_all(root.join(".hidden/.git")).unwrap();
    let found = checkouts(root);
    let paths: Vec<_> = found.iter().map(|c| c.path.strip_prefix(root).unwrap()).collect();
    assert_eq!(paths, [Path::new("a-clone"), Path::new("deep/x/b-clone")]);
    assert_eq!(found[0].branch.as_deref(), Some("issue-19225"));
    assert_eq!(found[0].date.as_deref(), Some("2026-10-19"));
    assert!(found[0].commit.is_some());
    // A repository itself is the only one named, never what is below it.
    assert_eq!(checkouts(&root.join("a-clone")).len(), 1);
}

#[test]
fn the_machines_own_folder_and_another_fuse_mount_are_no_projection() {
    for path in ["/home/cmux/work/plain", "/home/cmux/work/other"] {
        let answer = describe_with(Path::new(path), TABLE, None);
        assert_eq!(answer["projected"], false, "{path}");
        assert_eq!(answer["edits_reach_mac"], "never", "{path}");
    }
}

#[test]
fn a_malformed_name_is_no_projection_claim() {
    let table = "40 22 0:41 / /w rw - fuse.cmux cmux-projectionX rw\n41 22 0:41 / /v rw - fuse.cmux cmux-projection:%zz rw\n";
    assert_eq!(projection_of(Path::new("/w"), table), None);
    assert_eq!(projection_of(Path::new("/v"), table), None);
}
