//! The `ci-wait` and `landing` skills base Chief ships (hq docs/design/base-chief-upgrades.md):
//! they install with the other shared skills, name the waiters every user has (acpmux
//! `run_wait`/`pr_wait`/`pr_state`, else one `gh` watch with a deadline), never require a
//! tool only our fleet has, and pin every merge to the tested head.

use optchat_chief::skills;

fn installed(name: &str) -> String {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&name.to_owned()), "{written:?}");
    let text = std::fs::read_to_string(shared.join(name).join("SKILL.md")).unwrap();
    assert_eq!(skills::front_matter(&text).unwrap().0, name);
    text
}

#[test]
fn ci_wait_waits_once_with_what_every_user_has() {
    let text = installed("ci-wait");
    for word in [
        "run_wait",
        "pr_wait",
        "pr_state",
        "timeout 1800 gh run watch",
        "--log-failed",
        "base branch",
    ] {
        assert!(text.contains(word), "ci-wait lacks {word:?}");
    }
    // glaeda-gh is optional: named only as what run_wait uses when installed.
    assert!(
        !text.contains("glaeda-gh wait"),
        "ci-wait must not require glaeda-gh"
    );
    assert!(
        !text.contains("cmux-ci"),
        "ci-wait must not name our fleet's tools"
    );
}

#[test]
fn landing_pins_the_merge_and_names_what_blocks() {
    let text = installed("landing");
    for word in [
        "--match-head-commit",
        "--admin",
        "same way on the base branch",
        "Someone else's pull request",
    ] {
        assert!(text.contains(word), "landing lacks {word:?}");
    }
    assert!(
        !text.contains("land-judge") && !text.contains("glaeda"),
        "landing must not name our fleet's tools"
    );
}
