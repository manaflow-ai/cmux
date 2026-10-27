//! Outside input never panics the Chief (p10-stability-157,
//! plans/cmux-next/chrome-parity/p10-stability.md section D): cut, forged and
//! multi-byte text reaches each parser that used to index or slice it.

use std::path::Path;

use optchat_chief::agent_memory::settings::{expand_tilde, strip_jsonc};
use optchat_chief::backup::find_secret;
use optchat_chief::brain::images::short;
use optchat_chief::brain::media::{media_refs, without_images};
use optchat_chief::cli::Flags;
use optchat_chief::compactor::strip_preamble;
use optchat_chief::link_preview::meta::{meta_tags, title_tag};
use optchat_chief::skills::front_matter;
use optchat_chief::sub_watch::wait_on;
use optchat_chief::subagents::{cloud_repo, is_transient_start_failure};
use optchat_chief::workspaces::link_subagents;

/// Every prefix of `text` that ends on a character boundary.
fn prefixes(text: &str) -> impl Iterator<Item = &str> {
    text.char_indices()
        .map(|(at, _)| at)
        .chain([text.len()])
        .filter_map(|at| text.get(..at))
}

#[test]
fn html_meta_and_title_survive_every_cut() {
    let page = "<head><TITLE>Café &amp; &#x1F600; &#xFFFFFFFF; &bogus</title>\
                <meta property=og:title content='Ü \"x\"'><meta name=\"description\" content=\"é\"/><meta";
    for cut in prefixes(page) {
        let _ = meta_tags(cut);
        let _ = title_tag(cut);
    }
    let tags = meta_tags(page);
    assert_eq!(tags.get("og:title").map(String::as_str), Some("Ü \"x\""));
    assert_eq!(tags.get("description").map(String::as_str), Some("é"));
    assert_eq!(
        title_tag(page).as_deref(),
        Some("Café & 😀 &#xFFFFFFFF; &bogus")
    );
}

#[test]
fn jsonc_with_cut_comments_and_escapes_never_panics() {
    for text in [
        "/*",
        "/",
        "\"\\",
        "{\"a\": 1, /* x */ }",
        "// é\n{\"é\": [1,]}",
    ] {
        for cut in prefixes(text) {
            let _ = strip_jsonc(cut);
        }
    }
    assert_eq!(strip_jsonc("{\"a\": [1, 2,], } // c"), "{\"a\": [1, 2] } ");
    assert_eq!(strip_jsonc("/**/1"), "1");
    assert_eq!(strip_jsonc("\"/* kept */\""), "\"/* kept */\"");
}

#[test]
fn markdown_scanners_take_multibyte_and_cut_links() {
    let reply = "é ![x](/tmp/é.png) [a1](cmux://x) `a1 é` _a1_ ![";
    for cut in prefixes(reply) {
        let refs = media_refs(cut, None);
        let _ = without_images(cut, &refs.iter().collect::<Vec<_>>());
        let _ = link_subagents(cut, "optchat-chief:0123abcd", |id| {
            (id == "a1").then(|| "s-1".to_owned())
        });
    }
    assert_eq!(
        link_subagents("é a1, `a1`", "optchat-chief:0123abcd", |id| {
            (id == "a1").then(|| "s-1".to_owned())
        }),
        "é [a1](cmux://chief/0123abcd/session/s-1), `a1`"
    );
}

#[test]
fn command_lines_with_missing_values_are_words() {
    let args = |words: &[&str]| words.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    let flags = Flags::parse(&args(&["agents", "--cwd"]));
    assert_eq!(flags.words, args(&["agents", "--cwd"]));
    assert!(Flags::parse(&[]).words.is_empty());
    assert_eq!(wait_on("x"), None);
    assert_eq!(wait_on("chief fleet wait"), None);
}

#[test]
fn short_and_odd_texts_never_panic() {
    for text in [
        "",
        "é",
        "---",
        "---\n",
        "sk-",
        "ghp_é",
        "agent process closed",
        "~",
        "~é",
    ] {
        let _ = front_matter(text);
        let _ = find_secret(text);
        let _ = strip_preamble(text);
        let _ = is_transient_start_failure(text);
        let _ = cloud_repo(Some(text));
        let _ = expand_tilde(text, Path::new("/home/x"));
    }
    assert_eq!(expand_tilde("~", Path::new("/h")), Path::new("/h"));
    assert_eq!(expand_tilde("~/a", Path::new("/h")), Path::new("/h/a"));
    assert_eq!(expand_tilde("~a", Path::new("/h")), Path::new("~a"));
    assert_eq!(strip_preamble("Here:\n\nThe line"), "The line");
    assert_eq!(strip_preamble("Only:"), "Only:");
}

#[test]
fn a_hash_prefix_cuts_on_a_character_boundary() {
    assert_eq!(short("0123456789abcdef"), "0123456789ab");
    assert_eq!(short("aéééééé"), "aééééé");
    assert_eq!(short("é"), "é");
}

fn stream(events: &[serde_json::Value]) -> Result<Option<serde_json::Value>, String> {
    let body: String = events.iter().map(|e| format!("data: {e}\n\n")).collect();
    optchat_chief::native::read_until(body.as_bytes(), &|| false)
}

#[test]
fn a_content_block_that_is_not_an_object_fails_the_stream() {
    use serde_json::json;
    for (delta, stop) in [
        (json!({"type": "text_delta", "text": "a"}), false),
        (json!({"type": "signature_delta", "signature": "s"}), false),
        (json!({"type": "citations_delta", "citation": {}}), false),
        (
            json!({"type": "input_json_delta", "partial_json": "{}"}),
            true,
        ),
    ] {
        let mut events = vec![
            json!({"type": "message_start", "message": {"role": "assistant"}}),
            json!({"type": "content_block_start", "index": 0, "content_block": "x"}),
            json!({"type": "content_block_delta", "index": 0, "delta": delta}),
        ];
        if stop {
            events.push(json!({"type": "content_block_stop", "index": 0}));
        }
        events.push(json!({"type": "message_stop"}));
        assert_eq!(
            stream(&events),
            Err("a content block is not an object".to_owned())
        );
    }
}

/// The first index is a small gap, so the base (which padded up to any
/// index) fails on it before it meets u64::MAX.
#[test]
fn a_content_block_index_past_the_next_block_fails_the_stream() {
    use serde_json::json;
    for index in [json!(1), json!(u64::MAX), json!(-1), json!("0")] {
        let events = [
            json!({"type": "message_start", "message": {"role": "assistant"}}),
            json!({"type": "content_block_start", "index": index,
                   "content_block": {"type": "text", "text": ""}}),
            json!({"type": "message_stop"}),
        ];
        assert_eq!(
            stream(&events),
            Err("a content block starts out of order".to_owned()),
            "index {index}"
        );
    }
    let events = [
        json!({"type": "message_start", "message": {"role": "assistant"}}),
        json!({"type": "content_block_start", "index": 0,
               "content_block": {"type": "tool_use", "name": "t"}}),
        json!({"type": "content_block_delta", "index": 0,
               "delta": {"type": "input_json_delta", "partial_json": "{\"a\":1}"}}),
        json!({"type": "content_block_stop", "index": 0}),
        json!({"type": "content_block_start", "index": 1,
               "content_block": {"type": "text", "text": ""}}),
        json!({"type": "content_block_delta", "index": 1,
               "delta": {"type": "text_delta", "text": "hé"}}),
        json!({"type": "message_stop"}),
    ];
    let message = stream(&events).unwrap().unwrap();
    assert_eq!(
        message.get("content"),
        Some(
            &json!([{"type": "tool_use", "name": "t", "input": {"a": 1}},
                     {"type": "text", "text": "hé"}])
        )
    );
}
