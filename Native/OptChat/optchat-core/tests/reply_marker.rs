//! A user message that replies to an earlier one is logged with a
//! `(reply to #N: <quote>)` marker, and its summary line keeps the target as
//! `(re #N) `, which the host adds itself, so no compaction can drop it.

use std::cell::RefCell;
use std::collections::HashMap;

use optchat_core::*;

#[derive(Default)]
struct Mem {
    messages: RefCell<Vec<(Kind, String)>>,
    nodes: RefCell<HashMap<NodeId, String>>,
}

impl Store for Mem {
    fn message(&self, i: u64) -> (Kind, String) {
        self.messages.borrow()[i as usize].clone()
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.nodes.borrow().get(&id).cloned()
    }
}

/// Logs `text` as one user message; returns the compactor's work for it.
fn log_one(text: &str) -> (Mem, Memory, Vec<Work>) {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    store
        .messages
        .borrow_mut()
        .push((Kind::User, text.to_owned()));
    memory.append();
    let work = memory.pump(&store);
    (store, memory, work)
}

#[test]
fn the_marker_is_one_short_line() {
    assert_eq!(reply_marker(7, None), "(reply to #7)");
    assert_eq!(reply_marker(7, Some("  \n ")), "(reply to #7)");
    assert_eq!(
        reply_marker(128, Some("Deploy is green.\n\nPR #42 merged.")),
        "(reply to #128: Deploy is green. PR #42 merged.)"
    );
    let long = "word ".repeat(100);
    let marker = reply_marker(3, Some(&long));
    let quote = marker
        .strip_prefix("(reply to #3: ")
        .and_then(|q| q.strip_suffix("…)"))
        .expect("a cut quote ends with an ellipsis");
    assert_eq!(quote.chars().count(), REPLY_QUOTE);
    assert!(!marker.contains('\n'));
}

#[test]
fn only_a_marker_has_a_tag() {
    assert_eq!(reply_tag("(reply to #128: hi)\nok").as_deref(), Some("(re #128) "));
    assert_eq!(reply_tag("(reply to #9)\nok").as_deref(), Some("(re #9) "));
    assert_eq!(reply_tag("(reply to #)\nok"), None);
    assert_eq!(reply_tag("(reply to #9x)"), None);
    assert_eq!(reply_tag("please reply to #9"), None);
}

#[test]
fn a_long_reply_keeps_its_target_in_the_summary_line() {
    let text = format!(
        "{}\n{}",
        reply_marker(12, Some("Should I ship the tagged build?")),
        "Yes, ship it, but first rerun the flaky test. ".repeat(20)
    );
    let (store, memory, work) = log_one(&text);
    let [Work::Model { node }] = work.as_slice() else {
        panic!("a long message needs a model call: {work:?}");
    };
    let request = compact_request(&memory, &store, *node, "system".into()).unwrap();
    assert_eq!(request.cut.as_deref(), Some("(re #12) "));
    assert_eq!(request.room(), NODE - "(re #12) ".len());
    assert!(
        request
            .step
            .contains("Its line will start with \"(re #12) \", added for you"),
        "the model is told the tag is added: {}",
        request.step
    );
    let line = finish_line(&request, "user: ship it after rerunning the flaky test");
    assert_eq!(line, "(re #12) user: ship it after rerunning the flaky test");
}

#[test]
fn a_short_reply_is_its_own_line_marker_and_all() {
    let text = format!("{}\nyes", reply_marker(4, None));
    let (_, _, work) = log_one(&text);
    let [Work::Free { text: line, .. }] = work.as_slice() else {
        panic!("a short message needs no model call: {work:?}");
    };
    assert_eq!(line, "user: (reply to #4)\nyes");
}

#[test]
fn a_message_that_is_not_a_reply_gets_no_tag() {
    let (store, memory, work) = log_one(&"Plain long message. ".repeat(40));
    let [Work::Model { node }] = work.as_slice() else {
        panic!("a long message needs a model call: {work:?}");
    };
    let request = compact_request(&memory, &store, *node, "system".into()).unwrap();
    assert_eq!(request.cut, None);
    assert_eq!(request.room(), NODE);
}
