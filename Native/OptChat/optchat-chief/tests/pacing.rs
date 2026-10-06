//! G11 (brains/DESIGN-cmux-lawrence.md): the cloud owner refuses an agent
//! message within 2 s of the previous one (`agent_rate`) and limits agent turns
//! without a human. The brain coalesces messages it has not sent yet into one
//! `message.send`, waits out the gap before the next send, and retries an
//! `agent_rate` refusal with backoff under the same key, never dropping it.

use std::time::Duration;

use cmux_conversation::{Op, Part};
use optchat_chief::pacing::{backoff, coalesce, gap_wait};
use optchat_chief::state::OutboxEntry;

fn send(conversation: &str, key: &str, text: &str) -> OutboxEntry {
    OutboxEntry {
        conversation: conversation.into(),
        idempotency_key: key.into(),
        op: Op::MessageSend {
            client_msg_id: key.into(),
            parts: vec![Part::Text {
                text: text.into(),
                runs: None,
            }],
            reply_to: None,
        },
        rate_retried: false,
        not_before: None,
        attempted: false,
        rate_attempts: 0,
        previews_until: None,
    }
}

fn text_of(e: &OutboxEntry) -> String {
    match &e.op {
        Op::MessageSend { parts, .. } => parts
            .iter()
            .map(|p| match p {
                Part::Text { text, .. } => text.clone(),
                _ => String::new(),
            })
            .collect(),
        _ => String::new(),
    }
}

#[test]
fn unsent_messages_to_one_conversation_become_one_send_under_the_first_key() {
    let mut out = vec![
        send("c1", "k1", "[child a] done"),
        send("c1", "k2", "[child b] done"),
        send("c2", "k3", "other"),
    ];
    coalesce(&mut out);
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].idempotency_key, "k1");
    assert_eq!(text_of(&out[0]), "[child a] done\n\n[child b] done");
    assert_eq!(out[1].idempotency_key, "k3");
}

#[test]
fn a_message_already_tried_keeps_its_content() {
    let mut first = send("c1", "k1", "sent once");
    first.attempted = true;
    let mut out = vec![first, send("c1", "k2", "later")];
    coalesce(&mut out);
    assert_eq!(
        out.len(),
        2,
        "a tried key must keep its text (the owner dedupes by key)"
    );
}

#[test]
fn the_next_agent_message_waits_out_the_gap() {
    assert_eq!(gap_wait(Some(10_000), 2_000, 10_500), Some(1_500));
    assert_eq!(gap_wait(Some(10_000), 2_000, 12_000), None);
    assert_eq!(gap_wait(None, 2_000, 1), None);
}

#[test]
fn backoff_grows_from_the_gap_and_is_capped() {
    let gap = Duration::from_millis(2_000);
    assert_eq!(backoff(gap, 1), Duration::from_millis(2_000));
    assert_eq!(backoff(gap, 2), Duration::from_millis(4_000));
    assert_eq!(backoff(gap, 10), Duration::from_secs(60));
}
