use super::*;

#[test]
fn the_three_typed_requests_become_argv() {
    assert_eq!(
        argv(&json!({"customize": "try", "target": "pr:51234", "minutes": 15})).unwrap(),
        ["customize", "try", "pr:51234", "--minutes", "15"]
    );
    assert_eq!(
        argv(&json!({"customize": "try", "target": "darker"})).unwrap(),
        ["customize", "try", "darker"]
    );
    assert_eq!(argv(&json!({"customize": "keep"})).unwrap(), ["customize", "keep"]);
    assert_eq!(argv(&json!({"customize": "revert"})).unwrap(), ["customize", "revert"]);
    assert_eq!(
        argv(&json!({"customize": "go", "target": "pr:57001"})).unwrap(),
        ["customize", "go", "pr:57001"]
    );
}

#[test]
fn share_puts_each_target_on_another_cmux() {
    let share = |target: &str| share_plan(&json!({"customize": "share", "target": target}));
    assert_eq!(share("pr:59130"), Ok(Share::Line("cmux customize try pr:59130".into())));
    assert_eq!(share("branch:lane/x"), Ok(Share::Line("cmux customize try branch:lane/x".into())));
    assert_eq!(share("kept-night"), Ok(Share::Profile("kept-night".into())));
    assert_eq!(share("dir:/w/cmux"), Ok(Share::Dir("/w/cmux".into())));
    for bad in ["", "--help", "pr:x", "a b", "dir:--x"] {
        assert!(share(bad).is_err(), "{bad}");
    }
    assert!(share_plan(&json!({"customize": "try", "target": "pr:1"})).is_err());
    // A wrap-up action never carries a share: argv refuses it, so wrap_up drops it.
    assert!(argv(&json!({"customize": "share", "target": "pr:1"})).is_err());
    let dir = share_folder(std::path::Path::new("/home/a"), "kept-night");
    assert_eq!(dir, std::path::Path::new("/home/a/cmux-setups/kept-night"));
    assert_eq!(
        export_argv("kept-night", &dir),
        [
            "setup",
            "export",
            "/home/a/cmux-setups/kept-night",
            "--id",
            "local/kept-night",
            "--name",
            "kept-night",
            "--profile",
            "kept-night"
        ]
        .map(std::ffi::OsString::from)
    );
}

#[test]
fn a_folder_shares_only_its_pushed_branch() {
    let status = |ab: &str| {
        format!(
            "# branch.oid abc\n# branch.head lane/x\n# branch.upstream origin/lane/x\n# branch.ab {ab} -0\n"
        )
    };
    let ours = "https://github.com/manaflow-ai/cmux.git\n";
    assert_eq!(pushed_branch(&status("+0"), ours).as_deref(), Some("lane/x"));
    assert_eq!(
        pushed_branch(&status("+0"), "git@github.com:manaflow-ai/cmux").as_deref(),
        Some("lane/x")
    );
    assert_eq!(pushed_branch(&status("+2"), ours), None, "unpushed commits");
    assert_eq!(pushed_branch(&status("+0"), "https://github.com/me/cmux.git"), None, "a fork");
    assert_eq!(
        pushed_branch("# branch.head lane/x\n# branch.oid abc\n", ours),
        None,
        "no upstream"
    );
}

#[test]
fn anything_else_is_refused() {
    for bad in [
        json!({}),
        json!({"customize": "apply"}),
        json!({"customize": "try"}),
        json!({"customize": "try", "target": "--help"}),
        json!({"customize": "try", "target": "pr:x"}),
        json!({"customize": "try", "target": "sha:zz"}),
        json!({"customize": "try", "target": "dir:--x"}),
        json!({"customize": "try", "target": "a b"}),
        json!({"customize": "try", "target": "x;rm", "minutes": 5}),
        json!({"customize": "try", "target": "pr:1", "minutes": 0}),
        json!({"customize": "try", "target": "pr:1", "minutes": 241}),
        json!({"customize": "try", "target": "pr:1", "minutes": "5"}),
        json!({"customize": "go"}),
        json!({"customize": "go", "target": "branch:x"}),
        json!({"customize": "go", "target": "darker"}),
        json!({"customize": "go", "target": "pr:"}),
    ] {
        assert!(argv(&bad).is_err(), "{bad}");
    }
    assert!(valid_target("branch:lane/live-artifacts-chat") && valid_target("dir:/tmp/my dir"));
}
