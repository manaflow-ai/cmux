use super::{Code, executable_mappings, not_traced, provisionable};

#[test]
fn only_an_unsigned_user_daemon_on_a_cloud_machine_takes_a_provisioned_key() {
    assert!(provisionable(1000, false, true));
    // A root daemon's agents are root.
    assert!(!provisionable(0, false, true));
    // A signed daemon enrolls the app by its signature only.
    assert!(!provisionable(1000, true, true));
    // Not a Cloud machine (a developer's Linux box): the app's own keyed start only.
    assert!(!provisionable(1000, false, false));
}

#[test]
fn a_traced_daemon_is_refused() {
    assert!(not_traced("Name:\tacpmux\nTracerPid:\t0\nUid:\t1000\n"));
    assert!(!not_traced("Name:\tacpmux\nTracerPid:\t4242\n"));
    assert!(!not_traced("Name:\tacpmux\n"));
}

#[test]
fn executable_mappings_say_what_runs_and_whether_its_code_was_written() {
    let smaps = "\
55d0c0000000-55d0c1000000 r--p 00000000 fd:01 123                        /opt/cmux/store/abc/cmux-tui
Size:               4096 kB
Private_Dirty:         8 kB
55d0c1000000-55d0c2000000 r-xp 01000000 fd:01 123                        /opt/cmux/store/abc/cmux-tui
Size:              16384 kB
Private_Dirty:         0 kB
Anonymous:             0 kB
7f0000000000-7f0000100000 r-xp 00000000 fd:01 456                        /usr/lib/x86_64-linux-gnu/libc.so.6
Private_Dirty:         4 kB
Anonymous:             4 kB
7f0000400000-7f0000500000 rwxp 00000000 00:00 0
Private_Dirty:         0 kB
7ffc00000000-7ffc00002000 r-xp 00000000 00:00 0                          [vdso]
Private_Dirty:         0 kB
Anonymous:             0 kB
7f0000600000-7f0000700000 r-xp 00000000 00:01 99                         /memfd:x (deleted)
Private_Dirty:         0 kB
";
    let code = executable_mappings(smaps);
    assert_eq!(
        code,
        vec![
            Code {
                path: "/opt/cmux/store/abc/cmux-tui",
                file: Some((0xfd, 1, 123)),
                unmodified: true
            },
            // A patched copy-on-write page of a real file.
            Code {
                path: "/usr/lib/x86_64-linux-gnu/libc.so.6",
                file: Some((0xfd, 1, 456)),
                unmodified: false
            },
            // Anonymous executable memory.
            Code { path: "", file: Some((0, 0, 0)), unmodified: false },
            Code { path: "[vdso]", file: Some((0, 0, 0)), unmodified: true },
            Code { path: "/memfd:x (deleted)", file: Some((0, 1, 99)), unmodified: false },
        ]
    );
    assert!(code[3].kernel());
    assert!(!code[0].kernel());
}
