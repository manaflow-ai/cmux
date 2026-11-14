use super::{install_line, join_line, read_ticket};

/// A scratch folder removed at drop.
struct Dir(std::path::PathBuf);
impl Dir {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!("acpmux-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A fake `cmux` that appends its argv to `argv.log` and its stdin to
/// `stdin.log`, one run each.
#[cfg(unix)]
fn recording_cmux(dir: &std::path::Path) -> String {
    let (argv, stdin) = (dir.join("argv.log"), dir.join("stdin.log"));
    format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\ncat >> '{}'\n",
        argv.display(),
        stdin.display()
    )
}

#[cfg(unix)]
fn executable(path: &std::path::Path, text: &str) {
    crate::test_exec::write_executable(path, text);
}

/// Runs `line` with `sh -c` and `bin` first on PATH: (argv, stdin) of
/// the recording cmux.
#[cfg(unix)]
fn run_line(dir: &Dir, line: &str, home: &std::path::Path) -> (String, String) {
    let bin = dir.path().join("bin");
    let status = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(line)
        .env("HOME", home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .stdin(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "{line}");
    let read = |name: &str| std::fs::read_to_string(dir.path().join(name)).unwrap_or_default();
    (read("argv.log"), read("stdin.log"))
}

const TICKET: &str = "cmxt1.abc";

/// The line a person pastes on the new machine joins it even when the
/// install script it pipes into ignores its arguments, as the script
/// cmux.com served on 2026-10-22 did (it installed cmux and stopped), and
/// the ticket reaches `cmux host join` on stdin: no process has it in its
/// argv, where other users read it (`ps`, `/proc/PID/cmdline`).
#[cfg(unix)]
#[test]
fn the_pasted_line_joins_with_the_ticket_on_stdin_not_in_argv() {
    let dir = Dir::new("pair-line");
    let home = dir.path().join("home");
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    // An old install script: it installs the recording cmux and never
    // reads "$@".
    let cmux = dir.path().join("cmux-fixture");
    executable(&cmux, &recording_cmux(dir.path()));
    let script =
        format!("mkdir -p \"$HOME/.cmux/bin\"\ncp '{}' \"$HOME/.cmux/bin/cmux\"\n", cmux.display());
    let script_path = dir.path().join("install.sh");
    std::fs::write(&script_path, script).unwrap();
    executable(&bin.join("curl"), &format!("#!/bin/sh\ncat '{}'\n", script_path.display()));

    let line = install_line("https://cmux.example/install.sh", TICKET);
    let (argv, stdin) = run_line(&dir, &line, &home);
    assert_eq!(argv, "host join --serve\n", "{line}");
    assert_eq!(stdin, format!("{TICKET}\n"), "{line}");
    assert!(!argv.contains(TICKET), "the ticket is in argv: {line}");
}

/// `join_command`, for a machine with cmux already: the same, on PATH.
#[cfg(unix)]
#[test]
fn the_join_line_passes_the_ticket_on_stdin_not_in_argv() {
    let dir = Dir::new("join-line");
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    executable(&bin.join("cmux"), &recording_cmux(dir.path()));
    let line = format!("{} --advertise 'wss://new.example/acp'", join_line("cmux", "", TICKET));
    let (argv, stdin) = run_line(&dir, &line, dir.path());
    assert_eq!(argv, "host join --advertise wss://new.example/acp\n", "{line}");
    assert_eq!(stdin, format!("{TICKET}\n"), "{line}");
}

/// stdin holds one line: one trailing newline (or CRLF) trimmed; nothing
/// else, and no error repeats what it read.
#[test]
fn stdin_holds_one_ticket_line() {
    for ok in ["cmxt1.abc", "cmxt1.abc\n", "cmxt1.abc\r\n"] {
        assert_eq!(read_ticket(ok.as_bytes()).unwrap().as_str(), "cmxt1.abc", "{ok:?}");
    }
    let long = format!("cmxt1.{}", "a".repeat(5000));
    for bad in [
        "",
        "\n",
        "   \n",
        "cmxt1.abc\n\n",
        "cmxt1.abc\ncmxt1.def\n",
        "cmxt1.abc\nextra",
        "cmxt1.abc\r",
        long.as_str(),
    ] {
        let e = read_ticket(bad.as_bytes()).expect_err(bad);
        let text = format!("{e:#}");
        assert!(!text.contains("cmxt1.") && !text.contains("aaaa"), "{text}");
    }
    assert!(read_ticket(&b"cmxt1.\xff\n"[..]).is_err());
}
