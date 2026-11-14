use super::under_in;

const TABLE: &str = "  1     0     1 Ss   /sbin/init
 100     1   100 S    claude --print
 101   100   100 S    cmux mcp serve
 102   101   102 S    node server.js
 103     1   100 S    sleep 600
 104   100   100 Z    [rg] <defunct>
 105   100   105 Ss   python3 -m http.server
 200     1   200 S    other
";

#[test]
fn the_census_takes_children_group_members_and_skips_zombies() {
    let pids: Vec<u32> = under_in(TABLE, 100, 1).unwrap().iter().map(|u| u.pid).collect();
    assert_eq!(pids, vec![101, 102, 103, 105]);
}

#[test]
fn a_census_that_is_not_whole_says_nothing() {
    assert!(under_in(TABLE, 300, 1).is_none(), "a missing leader");
    assert!(under_in("100 1 100 S claude\nbad line\n", 100, 1).is_none(), "an unreadable line");
    assert!(under_in("104 1 104 Z claude\n", 104, 1).is_none(), "a zombie leader");
}

/// An app update swaps the file a running MCP server was started from; the census must still
/// know the server (it was "unknown" before, so its idle harness never hibernated).
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn exe_still_names_a_program_whose_file_was_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("server");
    // Copied by `cp`, never by this process: a test on another thread that starts a process
    // copies every open descriptor into the child until its exec, and a write descriptor
    // for `program` held then made its exec here fail with ETXTBSY ("Text file busy").
    let copied = std::process::Command::new("cp").arg("/bin/cat").arg(&program).status();
    assert!(copied.unwrap().success(), "cp /bin/cat {}", program.display());
    let mut child = std::process::Command::new(&program)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // `spawn` can return while the child is still mid-exec: Linux wakes a vfork parent before
    // it moves the child to the new image, so `/proc/<pid>/exe` still named this test binary
    // (7 of 60 runs). A line echoed back by `cat` is proof the child runs the copy.
    {
        use std::io::{BufRead, Write};
        child.stdin.as_mut().unwrap().write_all(b"ready\n").unwrap();
        let mut line = String::new();
        let mut out = std::io::BufReader::new(child.stdout.as_mut().unwrap());
        out.read_line(&mut line).unwrap();
        assert_eq!(line, "ready\n", "the copied program never ran");
    }
    let canonical = std::fs::canonicalize(&program).unwrap();
    // The update: the old file goes, a new one takes its path.
    std::fs::remove_file(&program).unwrap();
    std::fs::copy("/bin/cat", &program).unwrap();
    let seen = super::exe(child.id());
    let _ = child.kill();
    let _ = child.wait();
    let seen = seen.expect("a replaced program still has an executable");
    assert!(
        seen == program || seen == canonical,
        "exe {} is not {}",
        seen.display(),
        program.display()
    );
}

#[test]
fn argv_keeps_each_word_whole() {
    use super::{cmdline_argv, procargs2_argv};
    let app = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";
    let mut data = 2i32.to_ne_bytes().to_vec();
    data.extend_from_slice(format!("{app}\0\0\0{app}\0forum-mcp\0HOME=/x\0").as_bytes());
    assert_eq!(procargs2_argv(&data).unwrap(), [app, "forum-mcp"]);
    let mut short = 3i32.to_ne_bytes().to_vec();
    short.extend_from_slice(b"/bin/a\0/bin/a\0b");
    assert!(procargs2_argv(&short).is_none(), "cut short");
    // The exec path still names the program after an update replaced its file.
    assert_eq!(super::procargs2_exec_path(&data).unwrap(), std::path::Path::new(app));
    let mut relative = 1i32.to_ne_bytes().to_vec();
    relative.extend_from_slice(b"bin/a\0bin/a\0");
    assert!(super::procargs2_exec_path(&relative).is_none(), "not absolute");
    assert_eq!(
        crate::self_command::undeleted(format!("{app} (deleted)").into()),
        std::path::Path::new(app)
    );
    assert_eq!(crate::self_command::undeleted(app.into()), std::path::Path::new(app));
    assert_eq!(cmdline_argv(format!("{app}\0forum-mcp\0").as_bytes()).unwrap(), [app, "forum-mcp"]);
    assert_eq!(cmdline_argv(b"srv\0\0x\0").unwrap(), ["srv", "", "x"]);
    assert!(cmdline_argv(b"").is_none());
    assert!(cmdline_argv(b"node server.js --title").is_none(), "rewritten, no NUL");
    // `process.title` writes one string and pads the area with NULs: one word, then empties.
    assert_eq!(
        cmdline_argv(b"node /x/server.js --stdio\0\0\0").unwrap(),
        ["node /x/server.js --stdio", "", ""]
    );
}

#[test]
fn environ_reads_each_name_and_value() {
    use super::{env_pairs, procargs2_env};
    let mut data = 1i32.to_ne_bytes().to_vec();
    data.extend_from_slice(b"/bin/a\0\0/bin/a\0HOME=/x\0PATH=/b:/c\0X=a=b\0\0junk=1\0");
    let env = procargs2_env(&data).unwrap();
    assert_eq!(
        env,
        [("HOME", "/x"), ("PATH", "/b:/c"), ("X", "a=b")].map(|(k, v)| (k.into(), v.into()))
    );
    let mut apple = 1i32.to_ne_bytes().to_vec();
    apple.extend_from_slice(b"/bin/a\0/bin/a\0\0executable_path=/bin/a\0");
    assert!(procargs2_env(&apple).unwrap().is_empty(), "the kernel's strings are no environment");
    let mut bare = 1i32.to_ne_bytes().to_vec();
    bare.extend_from_slice(b"/bin/a\0/bin/a\0");
    assert!(procargs2_env(&bare).unwrap().is_empty(), "no environment");
    assert_eq!(
        env_pairs(b"A=1\0noeq\0=v\0B=\0"),
        [("A".into(), "1".into()), ("B".into(), String::new())]
    );
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn environ_reads_a_live_process() {
    let mut child = std::process::Command::new("/bin/sleep")
        .arg("30")
        .env("ACPMUX_TREE_ENV_PROBE", "a b=c")
        .spawn()
        .unwrap();
    let got = settled(|| {
        super::environ(child.id()).filter(|e| e.iter().any(|(k, _)| k == "ACPMUX_TREE_ENV_PROBE"))
    });
    let _ = child.kill();
    let _ = child.wait();
    let got = got.expect("the child's environment");
    assert!(got.contains(&("ACPMUX_TREE_ENV_PROBE".into(), "a b=c".into())), "{got:?}");
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn argv_reads_a_live_process() {
    let mut child = std::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
    let got = settled(|| super::argv(child.id()).filter(|a| a.len() == 2));
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(got.unwrap(), ["/bin/sleep", "30"]);
}

/// `read` once the new child has finished its exec: a read right after `spawn` can still see
/// it mid-exec (a CI run read no executable once). At most 2 s, then the last answer.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn settled<T>(read: impl Fn() -> Option<T>) -> Option<T> {
    for _ in 0..100 {
        if let Some(v) = read() {
            return Some(v);
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    read()
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn exe_is_what_the_kernel_runs_whatever_argv0_says() {
    use std::os::unix::process::CommandExt;
    let mut child = std::process::Command::new("/bin/sleep")
        .arg0("/opt/fake-server")
        .arg("30")
        .spawn()
        .unwrap();
    let pid = child.id();
    let argv =
        settled(|| super::argv(pid).filter(|a| a.first().is_some_and(|w| w == "/opt/fake-server")));
    let real = std::fs::canonicalize("/bin/sleep").unwrap();
    let same = |e: &std::path::PathBuf| std::fs::canonicalize(e).ok().as_ref() == Some(&real);
    let exe = settled(|| super::exe(pid).filter(same));
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(argv.unwrap(), ["/opt/fake-server", "30"]);
    assert!(exe.is_some(), "exe not read as /bin/sleep");
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn cwd_is_the_folder_a_live_process_runs_in() {
    let root = std::env::temp_dir().join(format!("tree-cwd-{} x", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let mut child =
        std::process::Command::new("/bin/sleep").arg("30").current_dir(&root).spawn().unwrap();
    let real = std::fs::canonicalize(&root).unwrap();
    let same = |c: &std::path::PathBuf| std::fs::canonicalize(c).ok().as_ref() == Some(&real);
    let got = settled(|| super::cwd(child.id()).filter(same));
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&root);
    assert!(got.is_some(), "cwd not read as {root:?}");
}

#[test]
fn the_daemons_own_group_is_never_the_harnesss() {
    let pids: Vec<u32> = under_in(TABLE, 100, 100).unwrap().iter().map(|u| u.pid).collect();
    assert_eq!(pids, vec![101, 102, 105]);
}
