use super::*;

#[test]
fn step_line_shape() {
    let line = serde_json::to_value(
        StepResult::new(Step::PeerBack, StepState::Warn, "no route back").with_fix("add a key"),
    )
    .unwrap();
    assert_eq!(line["step"], "peer-back");
    assert_eq!(line["state"], "warn");
    assert_eq!(line["fix"], "add a key");
}

#[test]
fn report_ok_ignores_warn_and_skip() {
    let r = Report::new(
        "hb",
        "huge-blue",
        vec![
            StepResult::new(Step::Reach, StepState::Ok, ""),
            StepResult::new(Step::PeerBack, StepState::Warn, ""),
            StepResult::new(Step::Identity, StepState::Skip, ""),
        ],
    );
    assert!(r.ok);
    let r =
        Report::new("hb", "huge-blue", vec![StepResult::new(Step::Daemon, StepState::Fail, "")]);
    assert!(!r.ok);
}
