use crate::json::is_compact_value;
use crate::row::{MAX_PREVIEW, MAX_ROW_TEXT, Outline, Placement, Row, RowError, RowHead, RowKind};

fn row(body: &str) -> Row<'_> {
    Row {
        id: 48211,
        rev: 1,
        kind: RowKind::Tool,
        turn: Some(9120),
        group: Some(48190),
        at: 1_794_480_726,
        open: false,
        body,
        est: 3,
    }
}

#[test]
fn a_row_encodes_to_the_designs_text() {
    let mut out = Vec::new();
    let placement = row(r#"{"name":"Bash","out":"ok"}"#).encode(None, &mut out).unwrap();
    assert_eq!(placement, Placement::Inline);
    assert_eq!(
        String::from_utf8(out).unwrap(),
        r#"{"id":48211,"rev":1,"kind":"tool","turn":9120,"group":48190,"at":1794480726,"open":false,"body":{"name":"Bash","out":"ok"},"est":3}"#
    );
}

#[test]
fn turn_and_group_are_left_out_when_absent() {
    let mut out = Vec::new();
    let bare = Row { turn: None, group: None, open: true, kind: RowKind::User, ..row("{}") };
    bare.encode(None, &mut out).unwrap();
    assert_eq!(
        String::from_utf8(out).unwrap(),
        r#"{"id":48211,"rev":1,"kind":"user","at":1794480726,"open":true,"body":{},"est":3}"#
    );
}

#[test]
fn every_row_text_is_one_compact_json_value_and_its_head_reads_back() {
    for (at, kind) in RowKind::ALL.into_iter().enumerate() {
        assert_eq!(RowKind::parse(kind.as_str()), Some(kind));
        let source = Row {
            id: 1 + at as u64 * 7919,
            rev: 1 + at as u32,
            kind,
            turn: at.is_multiple_of(2).then_some(at as u64 + 1),
            group: at.is_multiple_of(3).then_some(at as u64 + 2),
            at: 1_794_480_726 + at as u64,
            open: at.is_multiple_of(4),
            body: r#"{"md":["a \"quoted\" line","two"]}"#,
            est: at as u32,
        };
        let mut out = Vec::new();
        source.encode(None, &mut out).unwrap();
        assert!(is_compact_value(std::str::from_utf8(&out).unwrap()));
        let head = RowHead::parse(&out).unwrap();
        assert_eq!(
            (head.id, head.rev, head.kind, head.turn, head.group, head.at, head.open),
            (source.id, source.rev, kind, source.turn, source.group, source.at, source.open)
        );
        assert!(out[head.body_at..].starts_with(source.body.as_bytes()));
    }
    assert_eq!(RowKind::parse("nope"), None);
    assert_eq!(RowHead::parse(b"{\"id\":1}"), None);
    assert_eq!(RowHead::parse(b""), None);
}

#[test]
fn a_row_at_the_inline_limit_stays_inline_and_one_byte_more_goes_out_of_line() {
    let mut out = Vec::new();
    let frame = {
        row("\"\"").encode(None, &mut out).unwrap();
        out.len() - 2
    };
    // A body that makes the text exactly 16 KB.
    let fits = format!("\"{}\"", "x".repeat(MAX_ROW_TEXT - frame - 2));
    assert_eq!(row(&fits).encode(None, &mut out).unwrap(), Placement::Inline);
    assert_eq!(out.len(), MAX_ROW_TEXT);

    let over = format!("\"{}\"", "x".repeat(MAX_ROW_TEXT - frame - 1));
    let placement = row(&over).encode(None, &mut out).unwrap();
    assert_eq!(placement, Placement::Blob { bytes: over.len() as u64 });
    assert!(out.len() <= MAX_ROW_TEXT);
    let text = String::from_utf8(out.clone()).unwrap();
    assert!(is_compact_value(&text));
    assert!(text.contains(r#""body":{},"est":3,"blob":{"bytes":"#), "{}", &text[..200]);
}

#[test]
fn a_five_megabyte_body_leaves_a_head_and_a_preview_of_at_most_4_kb() {
    let output = "line one\n\"two\"\t\u{1}é漢字 ".repeat(250_000);
    let body = format!("{{\"name\":\"Bash\",\"out\":{:?}}}", "x".repeat(5 << 20));
    let mut out = Vec::new();
    let outline = Outline { head: r#"{"name":"Bash"}"#, preview: &output };
    let placement = row(&body).encode(Some(outline), &mut out).unwrap();
    assert_eq!(placement, Placement::Blob { bytes: body.len() as u64 });
    let text = String::from_utf8(out).unwrap();
    assert!(is_compact_value(&text), "the preview is escaped and cut on a character");
    assert!(text.len() <= MAX_ROW_TEXT);
    let preview = text.split_once(r#""preview":""#).unwrap().1.strip_suffix("\"}}").unwrap();
    assert!(preview.len() <= MAX_PREVIEW && preview.len() > MAX_PREVIEW - 8, "{}", preview.len());
    assert!(preview.starts_with(r#"line one\n\"two\"\t\u0001é漢字 "#));
    assert!(text.contains(r#""body":{"name":"Bash"},"#));
}

#[test]
fn a_row_that_cannot_be_encoded_says_why() {
    let mut out = Vec::new();
    assert_eq!(Row { id: 0, ..row("{}") }.encode(None, &mut out), Err(RowError::ZeroId));
    for bad in ["", "{", "{\"a\":1} ", "{ \"a\":1}", "{\"a\":01}", "\"a\nb\"", "[1,]", "nul", "1 2"]
    {
        assert_eq!(row(bad).encode(None, &mut out), Err(RowError::Body), "{bad:?}");
    }
    let large = format!("\"{}\"", "x".repeat(MAX_ROW_TEXT));
    let bad_head = Outline { head: "{", preview: "" };
    assert_eq!(row(&large).encode(Some(bad_head), &mut out), Err(RowError::Head));
    let big_head = Outline { head: &large, preview: "" };
    assert!(matches!(
        row(&large).encode(Some(big_head), &mut out),
        Err(RowError::TooLarge { bytes }) if bytes > MAX_ROW_TEXT
    ));
}

#[test]
fn the_json_check_takes_json_and_nothing_else() {
    for good in [
        "0",
        "-1.5e+10",
        "1E5",
        "true",
        "false",
        "null",
        "\"\"",
        "[]",
        "{}",
        "[1,[2,{\"a\":null}]]",
        "{\"a\":\"\\u00e9\\n\",\"b\":[true,false]}",
        "\"é漢\"",
    ] {
        assert!(is_compact_value(good), "{good}");
    }
    for bad in [
        "",
        " 1",
        "1 ",
        "[1, 2]",
        "{\"a\": 1}",
        "01",
        "1.",
        ".5",
        "-",
        "+1",
        "1e",
        "tru",
        "\"",
        "\"\\x\"",
        "\"\\u12g4\"",
        "{\"a\"}",
        "{a:1}",
        "[1,]",
        "{,}",
        "[",
        "{\"a\":1,}",
        "\"a\tb\"",
        "1,2",
    ] {
        assert!(!is_compact_value(bad), "{bad:?}");
    }
    let deep = format!("{}{}", "[".repeat(65), "]".repeat(65));
    assert!(!is_compact_value(&deep));
    let shallow = format!("{}{}", "[".repeat(64), "]".repeat(64));
    assert!(is_compact_value(&shallow));
}
