use super::*;

#[test]
fn the_line_is_the_contracts_shape() {
    assert_eq!(
        line(&json!({"held": true, "until_resume": true})).unwrap(),
        r#"{"held":true,"until_resume":true}"#
    );
    assert_eq!(
        line(&json!({"held": false, "until_resume": false})).unwrap(),
        r#"{"held":false,"until_resume":false}"#
    );
    assert!(line(&json!({})).is_err());
}
