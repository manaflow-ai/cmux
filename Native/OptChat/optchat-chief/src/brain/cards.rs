//! Cards that ride on the Chief's messages (issue 25830): suggested next
//! steps under a reply, and the Secure Store sign-in card of `send`.
//!
//! A reply names its next steps as trailing `[next: …]` lines; they leave
//! its text and become one `next_steps` card. An outbox entry keeps its
//! cards apart from its parts (`OutboxEntry::cards`), so link previews and
//! uploads (previews.rs, media.rs) still fill the text, and the cards go
//! after them when the op is sent. An owner that refuses cards gets the text
//! with each card as a line (outbox.rs).

use cmux_conversation::{Card, MAX_CARD_CHOICE_CHARS, MAX_CARD_CHOICES, Op, Part};

/// A reply's trailing `[next: …]` lines (at most [`MAX_CARD_CHOICES`],
/// empty and repeated ones dropped) and the text without them. A reply that
/// is nothing but such lines keeps its text and has no choices.
pub(crate) fn split_next_steps(text: &str) -> (String, Vec<String>) {
    let lines: Vec<&str> = text.trim_end().lines().collect();
    let mut cut = lines.len();
    while cut > 0 && next_line(lines[cut - 1].trim()).is_some() {
        cut -= 1;
    }
    let mut choices: Vec<String> = Vec::new();
    for choice in lines[cut..].iter().filter_map(|line| next_line(line.trim())) {
        if !choice.is_empty() && !choices.contains(&choice) {
            choices.push(choice);
        }
    }
    let rest = lines[..cut].join("\n").trim_end().to_owned();
    if rest.is_empty() || choices.is_empty() {
        return (text.to_owned(), Vec::new());
    }
    choices.truncate(MAX_CARD_CHOICES);
    (rest, choices)
}

/// The choice of one `[next: …]` line, cut to the owner's length.
fn next_line(line: &str) -> Option<String> {
    let inner = line.strip_prefix('[')?.strip_suffix(']')?;
    let (word, choice) = inner.split_once(':')?;
    if !word.trim().eq_ignore_ascii_case("next") {
        return None;
    }
    Some(
        choice
            .trim()
            .chars()
            .filter(|c| !c.is_control())
            .take(MAX_CARD_CHOICE_CHARS)
            .collect::<String>()
            .trim()
            .to_owned(),
    )
}

/// `op` with `cards` after its parts (a `message.send` only).
pub(crate) fn with_cards(op: &Op, cards: &[Card]) -> Op {
    let mut op = op.clone();
    if let Op::MessageSend { parts, .. } = &mut op {
        parts.extend(cards.iter().cloned().map(Part::Card));
    }
    op
}

/// What an owner that refuses cards gets: `text` (else the op's own text)
/// and one line per card.
pub(crate) fn text_fallback(text: Option<String>, op: &Op, cards: &[Card]) -> String {
    let text = text.unwrap_or_else(|| match op {
        Op::MessageSend { parts, .. } => parts
            .iter()
            .filter_map(|part| match part {
                Part::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        _ => String::new(),
    });
    let mut out = text.trim_end().to_owned();
    let inline = match op {
        Op::MessageSend { parts, .. } => parts
            .iter()
            .filter_map(|part| match part {
                Part::Card(card) => Some(card.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    };
    for card in inline.iter().chain(cards) {
        let line = card.text();
        if out.contains(&line) {
            continue;
        }
        if !out.is_empty() {
            out.push_str("\n\n");
        }
        out.push_str(&line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_next_lines_become_choices() {
        let (text, choices) = split_next_steps(
            "The retry was declined.\n\n[next: Try sending the Kernel update again]\n[Next: Show me the draft]\n",
        );
        assert_eq!(text, "The retry was declined.");
        assert_eq!(
            choices,
            ["Try sending the Kernel update again", "Show me the draft"]
        );
    }

    #[test]
    fn next_lines_in_the_middle_stay_text() {
        let reply = "[next: one]\nThen the rest of the reply.";
        assert_eq!(split_next_steps(reply), (reply.to_owned(), Vec::new()));
    }

    #[test]
    fn a_reply_of_only_next_lines_keeps_its_text() {
        let reply = "[next: one]";
        assert_eq!(split_next_steps(reply), (reply.to_owned(), Vec::new()));
    }

    #[test]
    fn at_most_three_distinct_choices_are_kept() {
        let (_, choices) =
            split_next_steps("Done.\n[next: a]\n[next: b]\n[next: a]\n[next: c]\n[next: d]");
        assert_eq!(choices, ["a", "b", "c"]);
        let card = Card::NextSteps { choices };
        assert!(cmux_conversation::valid_card(&card));
    }

    #[test]
    fn cards_follow_the_parts_and_fall_back_to_lines() {
        let op = Op::MessageSend {
            client_msg_id: "k".into(),
            parts: vec![Part::Text {
                text: "Done.".into(),
                runs: None,
            }],
            reply_to: None,
            answers: Vec::new(),
            answers_pending: Vec::new(),
            thread_root: None,
        };
        let cards = [Card::NextSteps {
            choices: vec!["Again".into()],
        }];
        let Op::MessageSend { parts, .. } = with_cards(&op, &cards) else {
            panic!("a send");
        };
        assert!(matches!(parts.as_slice(), [Part::Text { .. }, Part::Card(_)]));
        assert_eq!(text_fallback(None, &op, &cards), "Done.\n\n→ Again");
        let sign_in = [Card::SignIn {
            site: "linkedin.com".into(),
            url: None,
        }];
        let empty = with_cards(
            &Op::MessageSend {
                client_msg_id: "k".into(),
                parts: Vec::new(),
                reply_to: None,
                answers: Vec::new(),
                answers_pending: Vec::new(),
                thread_root: None,
            },
            &[],
        );
        assert_eq!(
            text_fallback(None, &empty, &sign_in),
            "Secure Store: sign in to linkedin.com"
        );
    }
}
