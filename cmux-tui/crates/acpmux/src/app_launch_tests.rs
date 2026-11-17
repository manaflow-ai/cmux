use super::*;

fn app(name: &str, id: &str, path: &str) -> App {
    App {
        name: name.into(),
        id: Some(id.into()),
        path: path.into(),
        exe: Some(Path::new(path).join("Contents/MacOS")),
    }
}

fn apps() -> Vec<App> {
    vec![
        app("Safari", "com.apple.Safari", "/Applications/Safari.app"),
        app("cmux NIGHTLY", "com.cmuxterm.app.nightly", "/Applications/cmux NIGHTLY.app"),
        app("cmux", "com.cmuxterm.app", "/Applications/cmux.app"),
        app("Safari", "com.example.other", "/Users/me/Applications/Safari.app"),
    ]
}

/// Arguments that a shell would read as commands, globs, expansions or redirections.
const HOSTILE: &[&str] = &[
    "; rm -rf ~",
    "$(touch /tmp/pwned)",
    "`id`",
    "a && b || c",
    "*",
    "> /etc/passwd",
    "it's \"quoted\"",
    "--args",
    "-n",
    "line\nbreak",
];

fn hostile() -> Vec<String> {
    HOSTILE.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn an_app_is_found_by_id_then_name_and_the_first_folder_wins() {
    let apps = apps();
    assert_eq!(
        resolve("com.apple.safari", &apps, None).unwrap().path,
        Path::new("/Applications/Safari.app")
    );
    assert_eq!(resolve("safari", &apps, None).unwrap().path, Path::new("/Applications/Safari.app"));
    assert_eq!(
        resolve("com.example.other", &apps, None).unwrap().path,
        Path::new("/Users/me/Applications/Safari.app")
    );
}

#[test]
fn cmux_is_the_daemons_own_app_else_nightly() {
    let apps = apps();
    let own = Path::new("/Applications/cmux.app");
    assert_eq!(resolve("cmux", &apps, Some(own)).unwrap().path, own);
    assert_eq!(
        resolve("cmux", &apps, None).unwrap().path,
        Path::new("/Applications/cmux NIGHTLY.app")
    );
    assert_eq!(
        resolve("CMUX", &apps, Some(Path::new("/elsewhere/x.app"))).unwrap().name,
        "cmux NIGHTLY"
    );
}

#[test]
fn an_unknown_app_is_not_found_and_says_to_list() {
    let refusal = resolve("Photoshop", &apps(), None).unwrap_err();
    assert_eq!(refusal, Refusal::NotFound("Photoshop".into()));
    assert_eq!(refusal.reason(), "app.not_found");
    assert_eq!(
        refusal.next("Photoshop", " --on mini"),
        "`cmux app list --on mini` lists the apps there"
    );
    let missing = resolve("/Applications/Nope.app", &apps(), None).unwrap_err();
    assert_eq!(missing.reason(), "app.not_found");
}

#[test]
fn a_flag_a_relative_path_or_a_control_character_is_no_app_name() {
    for bad in ["", "  ", "-n", "--args", "../x.app", "Apps/Safari.app", "Saf\u{7}ari"] {
        let params = json!({"app": bad});
        let refusal = LaunchRequest::from_params(&params).unwrap_err();
        assert_eq!(refusal.reason(), "app.invalid", "{bad:?}");
    }
    assert!(LaunchRequest::from_params(&json!({"app": "x", "args": "a b"})).is_err());
    assert!(LaunchRequest::from_params(&json!({"app": "x", "args": [1]})).is_err());
    assert!(LaunchRequest::from_params(&json!({"app": "x", "args": ["a\0b"]})).is_err());
    let many: Vec<String> = (0..=MAX_ARGS).map(|i| i.to_string()).collect();
    assert!(LaunchRequest::from_params(&json!({"app": "x", "args": many})).is_err());
}

#[test]
fn shell_metacharacters_reach_the_app_as_plain_arguments() {
    let request = LaunchRequest::from_params(&json!({"app": "Safari", "args": HOSTILE})).unwrap();
    assert_eq!(request.args, hostile());
    let safari = resolve("Safari", &apps(), None).unwrap();
    let argv = mac_open_argv(&safari, &request);
    // Each argument is one element after `--args`, unchanged: `open` passes them to the app as
    // its argv, and nothing between here and it is a shell.
    let after = argv.iter().position(|a| a == "--args").unwrap();
    assert_eq!(argv[after + 1..], hostile()[..]);
    assert_eq!(argv[..after], ["/usr/bin/open", "-g", "-a", "/Applications/Safari.app"]);
    // A desktop entry's field codes take them the same way.
    let linux = desktop_entry::argv(
        "gedit %U",
        &hostile(),
        "Text Editor",
        "/usr/share/applications/gedit.desktop",
    )
    .unwrap();
    assert_eq!(linux[0], "gedit");
    assert_eq!(linux[1..], hostile()[..]);
}

#[test]
fn a_launch_takes_no_focus_unless_asked() {
    let safari = resolve("Safari", &apps(), None).unwrap();
    let quiet = LaunchRequest { app: "Safari".into(), ..Default::default() };
    assert!(mac_open_argv(&safari, &quiet).contains(&"-g".to_owned()));
    let front = LaunchRequest { activate: true, ..quiet.clone() };
    assert!(!mac_open_argv(&safari, &front).contains(&"-g".to_owned()));
    let setup = LaunchRequest { hidden: true, new_instance: true, ..quiet };
    assert_eq!(mac_open_argv(&safari, &setup)[..4], ["/usr/bin/open", "-g", "-j", "-n"]);
}

#[test]
fn a_wait_is_bounded() {
    let r = LaunchRequest::from_params(&json!({"app": "x", "waitMs": 10_000_000u64})).unwrap();
    assert_eq!(r.wait, MAX_WAIT);
    let r = LaunchRequest::from_params(&json!({"app": "x"})).unwrap();
    assert_eq!(r.wait, DEFAULT_WAIT);
}

#[test]
fn every_refusal_says_what_to_run_next() {
    let all = [
        Refusal::NoSession("the login window is up".into()),
        Refusal::OtherUser("bob".into()),
        Refusal::NotFound("X".into()),
        Refusal::Invalid("bad".into()),
        Refusal::Unsupported,
        Refusal::Failed("boom".into()),
    ];
    for refusal in all {
        assert!(refusal.reason().starts_with("app."));
        assert!(!refusal.next("X", " --on mini").is_empty());
        assert!(!refusal.message("mini").is_empty());
    }
    assert_eq!(
        Refusal::NoSession("the login window is up".into()).message("mini"),
        "nobody is logged in on mini: the login window is up"
    );
}

#[test]
fn a_bundle_process_is_its_apps_and_another_bundles_is_not() {
    let safari = resolve("Safari", &apps(), None).unwrap();
    let running = vec![
        Running { pid: 1, exe: "/Applications/Safari.app/Contents/MacOS/Safari".into() },
        Running { pid: 2, exe: "/Applications/Safari.app/Contents/MacOS/Helpers/x".into() },
        Running { pid: 3, exe: "/Users/me/Applications/Safari.app/Contents/MacOS/Safari".into() },
    ];
    let pids: Vec<u32> = matching(&safari, &running).map(|r| r.pid).collect();
    assert_eq!(pids, [1]);
}

#[test]
fn launchservices_list_reads_each_apps_pid_and_program() {
    let out = r#"
 1) "Finder" ASN:0x0-0x1001:
    bundleID="com.apple.finder"
    bundle path="/System/Library/CoreServices/Finder.app"
    executable path="/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    pid = 456 type="Foreground" flavor=3 Version="15.0"
 2) "Safari" ASN:0x0-0x2002:
    bundleID="com.apple.Safari"
    bundle path="/Applications/Safari.app"
    pid = 789 type="Foreground"
 3) "NoPid" ASN:0x0-0x3003:
    executable path="/x"
"#;
    let running = lsappinfo_running(out);
    assert_eq!(running.len(), 2);
    assert_eq!(running[0].pid, 456);
    assert_eq!(
        running[0].exe,
        Path::new("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    );
    let safari = resolve("Safari", &apps(), None).unwrap();
    let pids: Vec<u32> = matching(&safari, &running).map(|r| r.pid).collect();
    assert_eq!(pids, [789]);
}

#[test]
fn a_desktop_entry_reads_its_launch_fields_and_quoting() {
    let text = "[Desktop Entry]\nType=Application\nName=Files\nExec=\"/opt/my app/bin\" --new-window %U\n\
                [Desktop Action new]\nExec=other\n";
    let entry = desktop_entry::parse(text).unwrap();
    assert_eq!(entry.name, "Files");
    assert!(entry.shown);
    let argv = desktop_entry::argv(&entry.exec, &["a b".into(), "c".into()], "Files", "/f.desktop");
    assert_eq!(argv.unwrap(), ["/opt/my app/bin", "--new-window", "a b", "c"]);
    // No file code: the arguments go at the end. `%%` is a percent; `%c` the name.
    let argv = desktop_entry::argv("app --title=%c 100%%", &["x".into()], "Files", "/f.desktop");
    assert_eq!(argv.unwrap(), ["app", "--title=Files", "100%", "x"]);
    // `%f` takes one argument only.
    assert_eq!(
        desktop_entry::argv("app %f", &["1".into(), "2".into()], "", "").unwrap(),
        ["app", "1"]
    );
    assert_eq!(desktop_entry::argv("app \"open", &[], "", ""), None);
    let hidden = "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n";
    assert!(!desktop_entry::parse(hidden).unwrap().shown);
}

#[cfg(target_os = "linux")]
#[test]
fn only_the_session_variables_come_from_the_user_manager() {
    let out = "PATH=/usr/bin\nDISPLAY=:0\nWAYLAND_DISPLAY=wayland-0\nSECRET_TOKEN=x\nXDG_RUNTIME_DIR=/run/user/1000\n";
    let vars = linux::session_vars(out);
    let keys: Vec<&str> = vars.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]);
}

#[test]
#[cfg(target_os = "linux")]
fn a_local_x_display_is_up_only_while_its_socket_exists() {
    let env = |k: &str, v: &str| vec![(k.to_owned(), v.to_owned())];
    let only_99 = |n: u32| n == 99;
    assert!(linux::display_up(&env("DISPLAY", ":99"), only_99));
    assert!(linux::display_up(&env("DISPLAY", ":99.0"), only_99));
    // A virtual display stopped when idle leaves its DISPLAY behind.
    assert!(!linux::display_up(&env("DISPLAY", ":100"), only_99));
    assert!(linux::display_up(&env("DISPLAY", "host:0"), only_99));
    assert!(linux::display_up(&env("WAYLAND_DISPLAY", "wayland-0"), only_99));
    assert!(!linux::display_up(&env("DISPLAY", ""), only_99));
    assert!(!linux::display_up(&[], only_99));
}

#[test]
#[cfg(target_os = "linux")]
fn the_virtual_display_is_read_from_cmux_rd_display() {
    assert_eq!(linux::display_line(":99\n").as_deref(), Some(":99"));
    assert_eq!(linux::display_line("starting\n :100 \n").as_deref(), Some(":100"));
    assert_eq!(linux::display_line("no display\n"), None);
}
