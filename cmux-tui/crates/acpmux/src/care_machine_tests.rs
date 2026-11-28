use super::*;

#[test]
fn the_timer_files_run_the_tick_every_five_minutes() {
    let files = timer_files(Path::new("/h"), Path::new("/bin/acpmux"), false);
    assert_eq!(files.len(), 2);
    assert!(files[0].0.ends_with(".config/systemd/user/cmux-care.service"));
    assert!(files[0].1.contains("ExecStart=\"/bin/acpmux\" care tick"));
    assert!(files[1].1.contains("OnUnitActiveSec=5min"));
    let mac = timer_files(Path::new("/h"), Path::new("/bin/acpmux"), true);
    assert!(mac[0].1.contains("<integer>300</integer>"));
    assert!(mac[0].1.contains("<string>care</string><string>tick</string>"));
}

#[test]
fn a_binary_path_with_spaces_or_markup_stays_one_word() {
    let exe = Path::new("/Users/a b/100% \"x\" $HOME/<&>'/acpmux");
    let unit = systemd_service(exe);
    assert!(
        unit.contains(r#"ExecStart="/Users/a b/100%% \"x\" $$HOME/<&>'/acpmux" care tick"#),
        "{unit}"
    );
    let plist = launch_agent(exe);
    assert!(
        plist.contains(
            "<string>/Users/a b/100% &quot;x&quot; $HOME/&lt;&amp;&gt;&apos;/acpmux</string>"
        ),
        "{plist}"
    );
}

#[test]
fn writing_a_file_twice_changes_nothing_the_second_time() {
    let dir = std::env::temp_dir().join(format!("care-timer-{}", now_ms()));
    let path = dir.join("a/b.timer");
    assert!(write_if_changed(&path, "x").unwrap());
    assert!(!write_if_changed(&path, "x").unwrap());
    assert!(write_if_changed(&path, "y").unwrap());
    let _ = std::fs::remove_file(&path);
}

#[cfg(unix)]
#[test]
fn writing_a_timer_stays_in_the_held_home_after_replacement() {
    crate::lost_home_race_tests::isolated(
        module_path!(),
        "writing_a_timer_stays_in_the_held_home_after_replacement",
        |home| {
            let path = home.join(".config/systemd/user/cmux-care.timer");
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, "old").unwrap();
            crate::config::hold_home();
            crate::lost_home_race_tests::replace(home);

            assert!(!write_if_changed(&path, "old").unwrap());
            assert!(
                home.with_extension("old").join(".config/systemd/user/cmux-care.timer").exists()
            );
            assert!(!path.exists(), "the replacement home stays untouched");

            assert!(write_if_changed(&path, "new").unwrap());
            assert_eq!(
                std::fs::read_to_string(
                    home.with_extension("old").join(".config/systemd/user/cmux-care.timer")
                )
                .unwrap(),
                "new"
            );
            assert!(!path.exists(), "the replacement home stays untouched");
        },
        |_, _| {},
    );
}
