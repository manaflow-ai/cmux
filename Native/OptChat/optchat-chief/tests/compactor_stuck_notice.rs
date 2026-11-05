//! https://github.com/manaflow-ai/cmux/issues/36026: Home showed "The
//! Chief's memory cannot summarize line 1634+1 (a request error)" while the
//! compactor's acpmux sessions only timed out under load (`session/new: no
//! answer within 200 s`). A transient failure that ran out of tries is a
//! quiet wait the host logs and retries; only a setup error or a request
//! error that repeats on every try posts the notice, named by its class.

use optchat_chief::brain::stuck_notice;
use optchat_core::NodeId;
use optchat_host::{Failure, Status};

fn status(node: NodeId, error: &str) -> Status {
    Status {
        messages: 1700,
        view_lines: 40,
        view_size: 6_000,
        budget: 8_000,
        unbuilt: 1,
        built: 3_000,
        busy: vec![node],
        failures: vec![Failure {
            node,
            error: error.to_owned(),
        }],
        stuck: vec![node],
        recovered: false,
        fatal: None,
        closed: false,
    }
}

const LINE: NodeId = NodeId::new(0, 1634);

#[test]
fn a_session_timeout_past_its_tries_posts_no_notice() {
    for error in [
        "starting a compactor session: session/new: no answer within 200 s",
        "the compactor session did not answer within 300 s",
        "starting a compactor session: session/new: agent_start did not finish within 90s; \
         its agent process (pid 26742) is alive",
        "API Error: 500 {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal\"}}",
    ] {
        assert_eq!(stuck_notice(&status(LINE, error)), None, "{error}");
    }
}

#[test]
fn a_repeating_request_error_names_its_class() {
    let text = stuck_notice(&status(
        LINE,
        "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\
         \"message\":\"A maximum of 4 blocks with cache_control may be provided.\"}}",
    ))
    .expect("a notice");
    assert!(text.contains("line 1634+1"), "{text}");
    assert!(text.contains("400 invalid_request_error"), "{text}");
    assert!(!text.contains("(a request error)"), "{text}");
}

#[test]
fn a_setup_error_posts_the_notice() {
    let text = stuck_notice(&status(
        LINE,
        "setup error: the compactor preset claude-haiku is missing in acpmux",
    ))
    .expect("a notice");
    assert!(text.contains("a setup error"), "{text}");
}
