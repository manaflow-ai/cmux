use super::*;

#[test]
fn grow_is_a_result_and_a_refusal_an_error() {
    let ok = result_for(
        &json!({"ok": true, "outcome": "grow", "message": "Growing", "machine": "vm_1"}),
    );
    assert_eq!(ok["isError"], false);
    assert_eq!(ok["content"][0]["text"], "grow: Growing");
    assert_eq!(
        ok["structuredContent"],
        json!({"outcome": "grow", "message": "Growing", "machine": "vm_1"})
    );
    let no = result_for(&json!({"ok": false, "error": {"code": "auth.refused", "message": "no"}}));
    assert_eq!(no["isError"], true);
}

#[tokio::test]
async fn a_bad_ask_never_reaches_the_socket() {
    assert_eq!(call(&json!({"vcpu": 4})).await["isError"], true);
}
