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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_results_pass_unchanged() {
        let s = "x".repeat(CAP);
        assert!(matches!(cap_tool_result(&s), Cow::Borrowed(_)));
    }

    #[test]
    fn long_results_keep_head_and_tail_within_cap() {
        // Multi-byte characters: the cap counts characters and cuts on boundaries.
        let s = format!("HEAD{}TAIL", "é".repeat(100_000));
        let capped = cap_tool_result(&s);
        assert_eq!(capped.chars().count(), CAP);
        assert!(capped.starts_with("HEAD"));
        assert!(capped.ends_with("TAIL"));
        let total = s.chars().count();
        let at = capped.find("[... ").unwrap() + 5;
        let cut: usize = capped[at..].split(' ').next().unwrap().parse().unwrap();
        let note = format!("\n\n[... {cut} of {total} characters cut here ...]\n\n");
        assert!(capped.contains(&note));
        // What was kept plus what was cut is the whole result.
        assert_eq!(CAP - note.chars().count() + cut, total);
    }
}
