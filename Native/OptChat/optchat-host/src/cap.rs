use std::borrow::Cow;

use optchat_core::CAP;

/// Caps a tool result at `CAP` characters, keeping its head and tail with a
/// note of what was cut between them (section 7): results are resent on
/// every later step of a call and land in the permanent log.
pub fn cap_tool_result(text: &str) -> Cow<'_, str> {
    let total = text.chars().count();
    if total <= CAP {
        return Cow::Borrowed(text);
    }
    // The note's length depends on the count it names; settle it in a few rounds.
    let mut note = String::new();
    let mut keep = CAP;
    for _ in 0..4 {
        let cut = total - keep;
        note = format!("\n\n[... {cut} of {total} characters cut here ...]\n\n");
        let next = CAP - note.chars().count();
        if next == keep {
            break;
        }
        keep = next;
    }
    let head = keep / 2;
    let tail = keep - head;
    let head_end = text.char_indices().nth(head).map_or(text.len(), |(b, _)| b);
    let tail_start = text
        .char_indices()
        .nth(total - tail)
        .map_or(text.len(), |(b, _)| b);
    Cow::Owned(format!(
        "{}{note}{}",
        &text[..head_end],
        &text[tail_start..]
    ))
}
