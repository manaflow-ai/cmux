//! A brain-host restart (an app update, a crash, a SIGTERM) cuts the running
//! turn. A turn that a human message woke runs again on the resume note
//! (crash.rs). A turn that a host note woke (a watch that fired, a `sleep`
//! wake, another Chief's message, an untold outcome) must run again too: the
//! note was consumed when it was logged, so nothing else wakes the Chief for
//! it, and the person ends up typing "go on".

mod common;

use common::*;
use optchat_chief::brain::Input;

const RESUMED: &str = "The server restarted, cutting the turn; nothing was lost: go on.";
const NOTE: &str = "[watch w1] CI on #123: the command exited with 0 after 4 min";

fn count(log: &[(String, String)], kind: &str, text: &str) -> usize {
    log.iter().filter(|(k, t)| k == kind && t == text).count()
}

#[test]
fn a_turn_a_note_woke_runs_again_after_a_host_restart() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.tx.send(Input::PeerChiefNote { text: NOTE.into() })
        .unwrap();
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The note's turn is running when the host goes away.
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle();
    let log = h.log();
    // The note is in the log once; the cut turn runs again on the resume
    // note, once, with no message from the person.
    assert_eq!(count(&log, "user", NOTE), 1, "{log:?}");
    assert_eq!(count(&log, "user", RESUMED), 1, "{log:?}");
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    // The resume turn is told what the cut turn was doing.
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let last = serde_json::to_string(prompts.last().expect("a resume turn")).unwrap();
    assert!(last.contains("[watch w1] CI on #123"), "{last}");
}
