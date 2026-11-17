use super::*;

fn turn(prompt: &str, answer: &str) -> Turn {
    Turn { prompt: prompt.into(), answer: answer.into(), prompt_at: None, answer_at: None }
}

#[test]
fn every_word_in_one_message_in_any_case_and_order() {
    let turns = [turn("Fix the Sidebar", "The row is NaN."), turn("thanks", "ok")];
    let needle = Needle::parse("nan ROW").expect("words");
    let hit = find(&needle, &turns).expect("hit");
    assert_eq!((hit.turn, hit.role, hit.matches), (0, "answer", 1));
    assert_eq!(hit.snippet, "The row is NaN.");
    // Words split between a prompt and its answer are no match.
    assert_eq!(find(&Needle::parse("sidebar nan").expect("words"), &turns), None);
}

#[test]
fn the_newest_message_is_the_hit_and_every_one_counts() {
    let turns = [turn("deploy it", "deployed"), turn("deploy again", "no")];
    let hit = find(&Needle::parse("deploy").expect("words"), &turns).expect("hit");
    assert_eq!((hit.turn, hit.role, hit.matches), (1, "prompt", 3));
}

#[test]
fn a_word_is_lowered_as_the_text_is() {
    // A final capital sigma: `str::to_lowercase` gives `ς` in a word's last place, `σ` alone.
    for (query, text) in [("ΟΣ", "ΟΣ"), ("ΟΣ", "ος"), ("ος", "ΟΣ"), ("οσ", "ος")] {
        let hit = find(&Needle::parse(query).expect("words"), &[turn(text, "")]);
        assert_eq!(hit.map(|hit| hit.snippet), Some(text.to_owned()), "{query} in {text}");
    }
}

#[test]
fn a_query_with_no_words_or_too_long_is_refused() {
    assert!(Needle::parse(" \n\t").is_err());
    assert!(Needle::parse(&"x".repeat(MAX_QUERY + 1)).is_err());
    assert_eq!(Needle::parse("a A a").expect("words").words, ["a"]);
}

#[test]
fn a_long_message_gives_the_text_around_the_word() {
    let text = format!("{} needle {}", "a ".repeat(100), "b ".repeat(100));
    let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
    assert!(hit.snippet.starts_with('…') && hit.snippet.ends_with('…'), "{}", hit.snippet);
    assert_eq!(hit.snippet.chars().count(), SNIPPET + 2);
    let at = hit.snippet.find("needle").expect("word in snippet");
    assert_eq!(hit.snippet[..at].chars().count(), BEFORE + 1);
    // Near the end, the snippet holds what comes before instead.
    let text = format!("{} needle", "a ".repeat(200));
    let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
    assert!(hit.snippet.starts_with('…') && hit.snippet.ends_with("needle"), "{}", hit.snippet);
    assert_eq!(hit.snippet.chars().count(), SNIPPET + 1);
}

#[test]
fn highlights_are_the_characters_of_every_word_in_any_case() {
    let needle = Needle::parse("row nan").expect("words");
    assert_eq!(needle.highlights("The Row is NaN, row."), vec![4, 5, 6, 11, 12, 13, 16, 17, 18]);
    // 'İ' lowercases to two characters: the positions still count the text's characters.
    assert_eq!(Needle::parse("x").expect("words").highlights("İx"), vec![1]);
    assert!(needle.highlights("nothing here").is_empty());
}

#[test]
fn whitespace_runs_are_one_space_and_a_case_change_that_grows_text_keeps_its_place() {
    let hit = find(&Needle::parse("b").expect("words"), &[turn("a\n\n  b", "")]).expect("hit");
    assert_eq!(hit.snippet, "a b");
    // 'İ' lowercases to two characters: the word after it is still found where it is.
    let text = format!("{}İ needle {}", "İ".repeat(60), "b ".repeat(100));
    let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
    let at = hit.snippet.find("needle").expect("word in snippet");
    assert_eq!(hit.snippet[..at].chars().count(), BEFORE + 1, "{}", hit.snippet);
}
