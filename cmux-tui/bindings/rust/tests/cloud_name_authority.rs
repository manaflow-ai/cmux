use cmux::TabSnapshot;
use serde_json::json;

#[test]
fn cloud_rename_authority_metadata_survives_typed_sdk_decoding() {
    let value = json!({
        "id":"tab_00000000000000000000000000000001",
        "pane_id":"pane_00000000000000000000000000000002",
        "name":"Logs / 東京", "index":0, "focused":true,
        "content_kind":"terminal",
        "content_id":"term_00000000000000000000000000000003",
        "extra":{"name_source":"user", "name_revision":"18446744073709551615"}
    });
    let decoded: TabSnapshot = serde_json::from_value(value).unwrap();
    assert_eq!(decoded.name.as_deref(), Some("Logs / 東京"));
    assert_eq!(decoded.extra["name_source"], "user");
    assert_eq!(decoded.extra["name_revision"], "18446744073709551615");
}
