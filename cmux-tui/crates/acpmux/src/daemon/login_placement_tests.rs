use super::*;

#[test]
fn an_ssh_started_daemon_goes_to_the_gui_session_only_when_there_is_one() {
    // Over ssh (not in the login session), the person's own home:
    assert_eq!(placement(Some(false), true, true, false), Placement::LoginJob);
    assert_eq!(placement(Some(false), true, false, false), Placement::NoGuiLogin);
    // In the login session already, or a test's home: here, as before.
    assert_eq!(placement(Some(true), true, true, false), Placement::InPlace);
    assert_eq!(placement(Some(true), true, false, false), Placement::InPlace);
    assert_eq!(placement(Some(false), false, true, false), Placement::InPlace);
    assert_eq!(placement(Some(false), false, false, false), Placement::InPlace);
}

#[test]
fn a_session_that_cannot_be_read_counts_as_outside_the_login_session() {
    assert_eq!(placement(None, true, true, false), Placement::LoginJob);
    assert_eq!(placement(None, true, false, false), Placement::NoGuiLogin);
    assert_eq!(placement(None, false, true, false), Placement::InPlace);
}

#[test]
fn a_keyed_start_over_ssh_stays_here_and_says_so() {
    assert_eq!(placement(Some(false), true, true, true), Placement::KeyedInPlace);
    assert_eq!(placement(Some(false), true, false, true), Placement::KeyedInPlace);
    assert_eq!(placement(Some(true), true, true, true), Placement::InPlace);
    assert_eq!(placement(Some(false), false, true, true), Placement::InPlace);
    let line = keyed_in_place_warning();
    assert!(line.contains(KEYED_IN_PLACE), "{line}");
    assert!(line.contains("keychain"), "{line}");
}

#[test]
fn a_home_that_leaves_the_persons_own_by_dot_dot_is_not_theirs() {
    let dir = std::env::temp_dir().join(format!("acpmux-own-{}", std::process::id()));
    let default = dir.join("home");
    std::fs::create_dir_all(default.join("dev")).unwrap();
    std::fs::create_dir_all(dir.join("outside")).unwrap();
    assert!(own_home(&default, &default));
    assert!(own_home(&default.join("dev"), &default));
    assert!(!own_home(&default.join("../outside"), &default));
    assert!(!own_home(&dir.join("outside"), &default));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_started_daemon_gets_this_commands_home_and_socket_absolute() {
    let cwd = Path::new("/work/here");
    let os = |s: &'static str| Some(std::ffi::OsStr::new(s));
    let env = daemon_env(Path::new(".acpmux-x"), os("run/a.sock"), cwd);
    assert_eq!(
        env,
        [
            ("ACPMUX_HOME", "/work/here/.acpmux-x".into()),
            ("ACPMUX_SOCKET", "/work/here/run/a.sock".into())
        ]
    );
    assert_eq!(daemon_env(Path::new("/abs/h"), None, cwd), [("ACPMUX_HOME", "/abs/h".into())]);
}

#[test]
fn equivalent_home_spellings_share_one_launchd_label() {
    let dir = std::env::temp_dir().join(format!("acpmux-label-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("h")).unwrap();
    std::fs::create_dir_all(dir.join("x")).unwrap();
    assert_eq!(job_label(&dir.join("h")), job_label(&dir.join("x/../h")));
    assert_ne!(job_label(&dir.join("h")), job_label(&dir.join("x")));
    assert_eq!(legacy_job_label(&dir.join("h")), legacy_job_label(&dir.join("x/../h")));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_homes_label_is_fixed_by_this_code_not_the_toolchain() {
    // FNV-1a 64 reference values: a std hasher change cannot move them.
    assert_eq!(label_for_bytes(b""), "com.cmux.acpmux.daemon.cbf29ce484222325");
    assert_eq!(label_for_bytes(b"a"), "com.cmux.acpmux.daemon.af63dc4c8601ec8c");
    assert_eq!(label_for_bytes(b"/Users/a/home"), "com.cmux.acpmux.daemon.3af804ca21d020f0");
    // A home that cannot be resolved is labelled as spelled.
    assert_eq!(
        job_label(Path::new("/nonexistent-acpmux-home/a")),
        label_for_bytes(b"/nonexistent-acpmux-home/a")
    );
    let legacy = legacy_job_label(Path::new("/nonexistent-acpmux-home/a"));
    assert!(legacy.starts_with(LABEL_PREFIX) && legacy.len() == LABEL_PREFIX.len() + 16);
}

const DOMAIN_PRINT: &str = "gui/501 = {
\ttype = gui
\tservices = {
\t\t       0      0 \tai.leo-workspace.memory-sync
\t\t       0     75 \tcom.cmux.acpmux.daemon.4ae0f8d39eeff3d2
\t\t   12345      - \tcom.cmux.acpmux.daemon.1111111111111111
\t\t       -      - \tcom.cmux.acpmux.daemon.2222222222222222
\t}

\tendpoints = {
\t\t       0      0 \tcom.cmux.acpmux.daemon.3333333333333333
\t}
}
";

#[test]
fn only_listed_daemon_jobs_with_no_process_are_sweep_candidates() {
    assert_eq!(
        stale_daemon_labels(DOMAIN_PRINT),
        ["com.cmux.acpmux.daemon.4ae0f8d39eeff3d2", "com.cmux.acpmux.daemon.2222222222222222"]
    );
    assert!(stale_daemon_labels("").is_empty());
    let many: String =
        (0..40).map(|i| format!("\t\t       0      0 \t{LABEL_PREFIX}{i:016x}\n")).collect();
    let print = format!("\tservices = {{\n{many}\t}}\n");
    assert_eq!(stale_daemon_labels(&print).len(), STALE_SWEEP_MAX);
}

#[cfg(unix)]
const JOB_PRINT: &str = "gui/501/com.cmux.acpmux.daemon.x = {
\tactive count = 0
\tpath = /Users/a/home/dev/daemon-login-session.plist
\ttype = LaunchAgent
\tstate = not running

\tprogram = /Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux
\targuments = {
\t\t/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux
\t\tdaemon
\t\trun
\t}
\tlast exit code = 75: EX_TEMPFAIL
}
";

// Unix paths: on Windows they are not absolute (no drive), and launchd is macOS-only.
#[cfg(unix)]
#[test]
fn only_an_ended_job_whose_program_is_gone_is_stale() {
    let app = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux");
    assert_eq!(stale_job_program(JOB_PRINT, |_| false).as_deref(), Some(app));
    // Its program is there: kept.
    assert_eq!(stale_job_program(JOB_PRINT, |p| p == app), None);
    // Running: kept, whatever its program.
    let running = JOB_PRINT.replace("state = not running", "state = running");
    assert_eq!(stale_job_program(&running, |_| false), None);
    // No `program = ` line: the first argument is the program.
    let no_program = JOB_PRINT.replace("\tprogram = ", "\tprogram_was = ");
    assert_eq!(stale_job_program(&no_program, |_| false).as_deref(), Some(app));
    // Nothing to read the program from: kept.
    assert_eq!(stale_job_program("state = not running\n", |_| false), None);
}

// Unix paths: on Windows they are not absolute (no drive), and launchd is macOS-only.
#[cfg(unix)]
#[test]
fn a_jobs_home_is_the_folder_of_the_plist_a_start_wrote() {
    assert_eq!(job_home(JOB_PRINT).as_deref(), Some(Path::new("/Users/a/home/dev")));
    let other = JOB_PRINT.replace("daemon-login-session.plist", "other.plist");
    assert_eq!(job_home(&other), None);
    assert_eq!(job_home("state = not running\n"), None);
}

#[test]
fn an_empty_acpmux_socket_is_not_handed_to_the_daemon() {
    let env = daemon_env(Path::new("/abs/h"), Some(std::ffi::OsStr::new("")), Path::new("/w"));
    assert_eq!(env, [("ACPMUX_HOME", "/abs/h".into())]);
}

#[test]
fn a_bootstrap_that_did_not_answer_but_loaded_the_job_is_waited_for() {
    assert_eq!(bootstrap_outcome(Some(true), || unreachable!()), Bootstrap::Job);
    assert_eq!(bootstrap_outcome(Some(false), || unreachable!()), Bootstrap::Failed);
    assert_eq!(bootstrap_outcome(None, || true), Bootstrap::Job);
    assert_eq!(bootstrap_outcome(None, || false), Bootstrap::Failed);
}

#[test]
fn a_failed_login_session_start_is_said_by_name_before_starting_here() {
    let line = start_failed_warning("launchctl bootstrap gui/501: 5: Input/output error");
    assert!(line.contains(START_FAILED), "{line}");
    assert!(line.contains("keychain"), "{line}");
    assert!(line.contains("Input/output error"), "{line}");
}

#[test]
fn status_tells_only_a_daemon_that_can_move_how_to_move_it() {
    assert_eq!(keychain_line(Some(true), true), None);
    let own = keychain_line(Some(false), true).unwrap();
    assert!(own.contains("--end-agents"), "{own}");
    let other = keychain_line(Some(false), false).unwrap();
    assert!(other.contains("keychain"), "{other}");
    assert!(!other.contains("--end-agents"), "{other}");
    assert!(!other.contains("in the login session)"), "{other}");
    assert!(keychain_line(None, false).unwrap().contains("unknown"));
}

#[test]
fn no_gui_login_is_said_by_name_with_its_consequence_and_fix() {
    let line = no_gui_login_warning();
    assert!(line.contains(NO_GUI_LOGIN), "{line}");
    assert!(line.contains("keychain"), "{line}");
    assert!(line.contains("log in at the screen"), "{line}");
    // Agents already running keep the session they started in: the fix says how to end them.
    assert!(line.contains("--end-agents"), "{line}");
}
