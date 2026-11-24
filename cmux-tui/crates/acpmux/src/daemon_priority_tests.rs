use super::*;

fn os(args: &[&str]) -> Vec<std::ffi::OsString> {
    args.iter().map(std::ffi::OsString::from).collect()
}

#[test]
fn the_daemon_asks_below_default_and_back_to_default_from_an_agents_nice() {
    assert_eq!(nice_steps(0), vec![DAEMON_NICE]);
    // A daemon a CLI under an agent started inherited +5: at least back to the default.
    assert_eq!(nice_steps(5), vec![DAEMON_NICE, 0]);
    assert!(nice_steps(DAEMON_NICE).is_empty());
    assert!(nice_steps(-10).is_empty());
}

#[test]
fn a_refused_nice_keeps_the_daemon_and_says_why() {
    assert_eq!(lower_nice(0, |_| true), Knob::Took("-5".into()));
    assert_eq!(lower_nice(5, |s| s == 0), Knob::Took("0 (wanted -5)".into()));
    let refused = lower_nice(5, |_| false);
    assert_eq!(
        refused,
        Knob::Refused(
            "inherited nice 5 from caller, kept: lowering needs CAP_SYS_NICE or RLIMIT_NICE \
                 (ulimit -e)"
                .into()
        )
    );
    let mut asked = Vec::new();
    lower_nice(-10, |s| {
        asked.push(s);
        true
    });
    assert!(asked.is_empty(), "never raises a nice it was given");
}

#[test]
fn the_report_is_one_line_with_every_knob() {
    let report = Report {
        knobs: vec![
            ("nice", lower_nice(0, |_| false)),
            ("cpu.weight", weight_knob(Some("1000\n"), "cpu")),
            ("io.weight", weight_knob(None, "io")),
        ],
    };
    let line = report.line();
    assert!(!line.contains('\n'));
    assert_eq!(
        line,
        "daemon priority: nice refused, kept 0: lowering needs CAP_SYS_NICE or RLIMIT_NICE \
             (ulimit -e); cpu.weight took 1000; io.weight n/a (no io controller in this cgroup)"
    );
}

#[test]
fn only_daemon_run_is_the_daemon() {
    assert!(is_daemon_run(&os(&["daemon"])));
    assert!(is_daemon_run(&os(&["daemon", "run", "--take-over"])));
    assert!(is_daemon_run(&os(&["--json", "daemon", "run"])));
    assert!(!is_daemon_run(&os(&["daemon", "status"])));
    assert!(!is_daemon_run(&os(&["ls"])));
    assert!(!is_daemon_run(&os(&[])));
}
