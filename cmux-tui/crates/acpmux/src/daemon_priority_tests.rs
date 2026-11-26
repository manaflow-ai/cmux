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
fn a_daemon_in_a_unit_without_weights_asks_for_them_once() {
    let unit = "/user.slice/user-1006.slice/user@1006.service/app.slice/acpmux.service";
    assert!(raise_weight_at_runtime(unit, Some("100\n")));
    assert!(!raise_weight_at_runtime(unit, Some("1000\n")), "acpmux's own unit already has it");
    assert!(!raise_weight_at_runtime(unit, None), "no cpu controller: nothing to ask");
    let detached = "/user.slice/user-1006.slice/session-4.scope";
    assert!(!raise_weight_at_runtime(detached, Some("100")), "only its own unit");
    assert!(!raise_weight_at_runtime("/app.slice/acpmux.service.bak", Some("100")));
    assert_eq!(
        raised_knob(Some("100\n"), Some("1000\n")),
        Knob::Took("1000 (raised from 100 at runtime)".into())
    );
    let unit_text = crate::cli::hosts::SYSTEMD_UNIT;
    assert!(unit_text.contains(&format!("CPUWeight={UNIT_WEIGHT}\n")), "same as acpmux's unit");
    assert!(unit_text.contains(&format!("IOWeight={UNIT_WEIGHT}\n")));
    assert_eq!(
        raised_knob(Some("100"), None),
        Knob::Refused("kept 100: systemctl set-property failed".into())
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
