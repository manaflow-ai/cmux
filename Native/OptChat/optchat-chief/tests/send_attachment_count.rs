use optchat_chief::tools::Call;
use serde_json::json;

#[test]
fn send_parses_every_attachment_reference_without_a_count_cap() {
    let paths: Vec<String> = (0..4096).map(|i| format!("/tmp/report-{i}.bin")).collect();
    let Call::Send(call) = Call::parse("send", &json!({"attachments": paths})).unwrap() else {
        panic!("not a send");
    };
    assert_eq!(call.attachments, paths);
    assert!(Call::parse("send", &json!({"attachments": ["/tmp/a", null]})).is_err());
}
