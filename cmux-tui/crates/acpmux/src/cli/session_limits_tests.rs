use super::*;

#[test]
fn describe_names_each_limit_and_its_source() {
    let l = json!({
        "maxRunning": 16, "maxRunningSource": "default", "running": 3, "queued": 2,
        "maxChildren": 50, "maxChildrenSource": "settings",
        "maxDepth": 3, "maxDepthSource": "inherited",
    });
    assert_eq!(
        describe(&l),
        "running 3 of 16 at once (default), 2 queued\nopen at most 50 (settings)\nnesting at most 3 deep (inherited)\n"
    );
}

#[test]
fn describe_from_an_older_daemon_marks_what_it_lacks() {
    let l = json!({"maxChildren": 50, "maxChildrenSource": "default", "maxDepth": 3, "maxDepthSource": "default"});
    assert!(describe(&l).starts_with("running ? of ? at once (unknown), ? queued\n"));
}
