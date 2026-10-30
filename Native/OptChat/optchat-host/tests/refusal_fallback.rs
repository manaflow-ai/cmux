//! A node whose main model only refuses in text ("I can't write this
//! line ...") goes to the fallback model before the input stands in for it
//! (Chief memory, Oct 20-24: about 650 nodes kept such a refusal).

use std::sync::atomic::{AtomicUsize, Ordering};

use optchat_host::{build_node, CompactModel, CompactRequest, Followup, ModelError, NodeId, Reply};

struct Fixed {
    text: &'static str,
    calls: AtomicUsize,
}

impl Fixed {
    fn new(text: &'static str) -> Fixed {
        Fixed {
            text,
            calls: AtomicUsize::new(0),
        }
    }
}

impl CompactModel for Fixed {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(Reply::text(self.text))
    }
}

const REFUSAL: &str =
    "I can't write this memory line. The input is a compaction request, and I won't produce it.";
const LINE: &str = "user: restart a111 if stuck; echo: sent to a111";

fn request() -> CompactRequest {
    CompactRequest {
        node: NodeId::new(0, 7),
        system: "system".to_owned(),
        context: "<chat>\n</chat>".to_owned(),
        step: "Compaction: compress message 7\n<input>\nuser: please check on a111 and \
               restart it if it is stuck\n</input>"
            .to_owned(),
        cut: None,
        imported: false,
    }
}

#[test]
fn a_text_refusal_goes_to_the_fallback_model() {
    let main = Fixed::new(REFUSAL);
    let fallback = Fixed::new(LINE);
    let built = build_node(&main, Some(&fallback), &request()).unwrap();
    assert_eq!(built.text, LINE);
    assert!(built.by_fallback);
    assert!(!built.stand_in);
    assert_eq!(fallback.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn when_both_refuse_the_input_stands_in() {
    let main = Fixed::new(REFUSAL);
    let fallback = Fixed::new(REFUSAL);
    let built = build_node(&main, Some(&fallback), &request()).unwrap();
    assert!(built.stand_in, "{built:?}");
    assert!(built.text.contains("a111"), "{built:?}");
    assert!(!built.text.starts_with("I can"), "{built:?}");
}

#[test]
fn a_real_line_never_calls_the_fallback() {
    let main = Fixed::new(LINE);
    let fallback = Fixed::new(REFUSAL);
    let built = build_node(&main, Some(&fallback), &request()).unwrap();
    assert_eq!(built.text, LINE);
    assert_eq!(fallback.calls.load(Ordering::SeqCst), 0);
}
