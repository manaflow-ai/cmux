//! The conversation client rules (src/conversation_rules.rs) against every
//! golden vector in tests/cases/conversation_rules.json, which encode what
//! the Swift client did (each case names its Swift source).

use cmux::conversation_rules::{call, policy, upload_plan};
use serde::Deserialize;
use serde_json::{Value, json};

const CASES: &str = include_str!("cases/conversation_rules.json");
/// The corpus's code for a rule this build does not know.
const UNKNOWN_RULE: i32 = -3;

#[derive(Deserialize)]
struct Corpus {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    op: String,
    request: Value,
    expect: Option<Value>,
    code: Option<i32>,
    /// `plan`: an `upload_plan` case whose `expect` is the plan itself; other
    /// `upload_plan` cases list every chunk, as the Swift client sent them.
    #[serde(default)]
    shape: Option<String>,
}

/// An `upload_plan` reply with every chunk listed, each one asked for
/// through `upload_chunk`: the shape the Swift client's vectors record.
fn with_chunks(plan: &Value) -> Value {
    let Some(pieces) = plan.get("pieces").and_then(Value::as_array) else {
        return plan.clone();
    };
    let pieces: Vec<Value> = pieces
        .iter()
        .map(|piece| {
            let count = piece["chunk_count"].as_u64().expect("chunk_count");
            let chunks: Vec<Value> = (0..count)
                .map(|index| {
                    let request = json!({"size": piece["size"], "sent_before": piece["sent_before"],
                                         "total": plan["total"], "index": index});
                    call("upload_chunk", &request).expect("a known rule").expect("a chunk")
                })
                .collect();
            json!({"variant": piece["variant"], "size": piece["size"], "chunks": chunks})
        })
        .collect();
    json!({"pieces": pieces})
}

/// Equal JSON, with numbers equal to 1e-12 (progress fractions).
fn same(actual: &Value, expect: &Value) -> bool {
    match (actual, expect) {
        (Value::Number(a), Value::Number(b)) => match (a.as_f64(), b.as_f64()) {
            (Some(a), Some(b)) => (a - b).abs() < 1e-12 && a.fract().eq(&0.0) == b.fract().eq(&0.0),
            _ => a == b,
        },
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len() && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
        }
        _ => actual == expect,
    }
}

#[test]
fn every_golden_vector() {
    let corpus: Corpus = serde_json::from_str(CASES).expect("tests/cases/conversation_rules.json");
    assert!(corpus.cases.len() > 50);
    let mut failures = Vec::new();
    for case in &corpus.cases {
        let actual = match call(&case.op, &case.request) {
            None => Err(UNKNOWN_RULE),
            Some(Ok(value)) if case.op == "upload_plan" && case.shape.is_none() => {
                Ok(with_chunks(&value))
            }
            Some(Ok(value)) => Ok(value),
            Some(Err(reject)) => Ok(json!({"error": reject.code()})),
        };
        let ok = match (&actual, &case.expect, case.code) {
            (Ok(value), Some(expect), None) => same(value, expect),
            (Err(code), None, Some(expected)) => *code == expected,
            _ => false,
        };
        if !ok {
            failures.push(format!(
                "{}: got {actual:?}, want {:?} {:?}",
                case.name, case.expect, case.code
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} cases differ:\n{}",
        failures.len(),
        corpus.cases.len(),
        failures.join("\n")
    );
}

#[test]
fn the_policy_names_the_daemon_limits() {
    assert_eq!(policy()["max_page"], 500);
    assert_eq!(policy()["attachment_chunk_bytes"], 4 << 20);
}

#[test]
fn an_upload_plan_covers_a_large_file_exactly() {
    let size: u64 = 1 << 30;
    let attachment = json!({"byte_count": size});
    let plan = upload_plan(&attachment, None, false, false).unwrap();
    let piece = plan.pieces[0];
    assert_eq!(piece.chunk_count(), 256);
    let mut next = 0;
    for chunk in piece.chunks(plan.total) {
        assert_eq!(chunk.offset, next);
        next += chunk.length;
        assert!(chunk.progress <= 0.99);
    }
    assert_eq!(next, size);
}

#[test]
fn a_u64_max_original_plans_in_constant_memory() {
    let attachment = json!({"byte_count": u64::MAX});
    let plan = upload_plan(&attachment, None, false, false).unwrap();
    let piece = plan.pieces[0];
    let last = piece.chunk_count() - 1;
    let end = piece.chunk(last, plan.total).unwrap();
    assert_eq!(end.offset + end.length, u64::MAX);
    assert!(piece.chunk(last + 1, plan.total).is_none());
    // The plan holds one piece and no chunk list.
    assert_eq!(size_of_val(&plan.pieces[..]), size_of_val(&piece));
}

#[test]
fn sizes_and_offsets_past_u64_are_refused_not_wrapped() {
    let max = u64::MAX;
    let plan = call(
        "upload_plan",
        &json!({"attachment": {"byte_count": max, "poster": {"byte_count": 1}},
                "needs": ["original", "poster"], "has_poster_file": true}),
    )
    .expect("a known rule");
    assert_eq!(plan.unwrap_err().code(), "invalid");
    let read = call("read_next", &json!({"offset": max, "received": 1})).expect("a known rule");
    assert_eq!(read.unwrap_err().code(), "invalid");
    let fits = call("read_next", &json!({"offset": max - 1, "received": 1})).expect("a known rule");
    assert_eq!(fits.unwrap(), json!({"offset": max}));
}
