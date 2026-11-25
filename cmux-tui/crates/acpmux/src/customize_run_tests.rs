use super::*;

#[test]
fn the_three_typed_requests_become_argv() {
    assert_eq!(
        argv(&json!({"customize": "try", "target": "pr:51234", "minutes": 15})).unwrap(),
        ["customize", "try", "pr:51234", "--minutes", "15"]
    );
    assert_eq!(
        argv(&json!({"customize": "try", "target": "darker"})).unwrap(),
        ["customize", "try", "darker"]
    );
    assert_eq!(argv(&json!({"customize": "keep"})).unwrap(), ["customize", "keep"]);
    assert_eq!(argv(&json!({"customize": "revert"})).unwrap(), ["customize", "revert"]);
}

#[test]
fn anything_else_is_refused() {
    for bad in [
        json!({}),
        json!({"customize": "apply"}),
        json!({"customize": "try"}),
        json!({"customize": "try", "target": "--help"}),
        json!({"customize": "try", "target": "pr:x"}),
        json!({"customize": "try", "target": "sha:zz"}),
        json!({"customize": "try", "target": "dir:--x"}),
        json!({"customize": "try", "target": "a b"}),
        json!({"customize": "try", "target": "x;rm", "minutes": 5}),
        json!({"customize": "try", "target": "pr:1", "minutes": 0}),
        json!({"customize": "try", "target": "pr:1", "minutes": 241}),
        json!({"customize": "try", "target": "pr:1", "minutes": "5"}),
    ] {
        assert!(argv(&bad).is_err(), "{bad}");
    }
    assert!(valid_target("branch:lane/live-artifacts-chat") && valid_target("dir:/tmp/my dir"));
}
