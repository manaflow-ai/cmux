use super::*;
use acpmux_list_types::Summary;

#[test]
fn summary_delta_preserves_opaque_json_bytes() {
    let raw = r#"{ "opaque" : [1,  2], "text": "\u0061" }"#;
    let mut summary = Summary::new("raw");
    summary.extra = serde_json::value::RawValue::from_string(raw.into()).unwrap();
    let frame = delta_frame(&DeltaFrame {
        sid: "s".into(),
        replay: Some(ReplayMark::End),
        ops: vec![DeltaOp::Summary { seq: 1, summary }],
    })
    .unwrap();
    let decoded: DeltaFrame<Summary> = frame.decode_json().unwrap();
    let Some(DeltaOp::Summary { summary, .. }) = decoded.ops.first() else {
        panic!("missing summary")
    };
    assert_eq!(summary.extra.get(), raw);
}
