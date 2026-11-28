use super::*;

#[test]
fn machine_tools_name_one_action_each() {
    let r = request("machine_read", &json!({"machine": "mac", "path": "/tmp/a"})).unwrap();
    assert_eq!(r, json!({"machine": "mac", "action": "fs.read", "params": {"path": "/tmp/a"}}));
    let r = request(
        "machine_read",
        &json!({"machine": "mac", "op": "grep", "path": "/tmp", "pattern": "x", "limit": 5}),
    )
    .unwrap();
    assert_eq!(r["action"], "fs.grep");
    assert_eq!(r["params"], json!({"root": "/tmp", "pattern": "x", "limit": 5}));
    let r = request(
        "machine_edit",
        &json!({"machine": "mac", "path": "/tmp/a", "edits": [{"old": "a", "new": "b"}], "expect_sha256": "s"}),
    )
    .unwrap();
    assert_eq!(r["action"], "fs.edit");
    let r = request("machine_exec", &json!({"machine": "mac", "command": "uname -a"})).unwrap();
    assert_eq!(r["params"]["argv"], json!(["/bin/sh", "-c", "uname -a"]));
    let r = request("machine_exec", &json!({"machine": "mac", "argv": ["uname"]})).unwrap();
    assert_eq!(r["params"], json!({"argv": ["uname"]}));
    // A read tool never names a write or a command, whatever its arguments say.
    let r = request(
        "machine_read",
        &json!({"machine": "mac", "path": "/tmp/a", "text": "x", "argv": ["rm"], "_level": "full"}),
    )
    .unwrap();
    assert_eq!(r["action"], "fs.read");
    assert_eq!(r["params"], json!({"path": "/tmp/a"}));
    for (name, args) in [
        ("machine_read", json!({"path": "/tmp/a"})),
        ("machine_read", json!({"machine": "mac"})),
        ("machine_read", json!({"machine": "mac", "path": "/tmp", "op": "glob"})),
        ("machine_read", json!({"machine": "mac", "path": "/tmp", "op": "exec"})),
        ("machine_edit", json!({"machine": "mac", "path": "/tmp/a"})),
        ("machine_edit", json!({"machine": "mac", "path": "/tmp/a", "text": "x", "patch": "y"})),
        ("machine_edit", json!({"machine": "mac", "text": "x"})),
        ("machine_exec", json!({"machine": "mac"})),
        ("machine_exec", json!({"machine": "mac", "command": "ls", "argv": ["ls"]})),
    ] {
        assert!(request(name, &args).is_err(), "{name} {args}");
    }
}

#[test]
fn machine_tools_show_a_file_and_a_command_as_text() {
    assert_eq!(text("fs.read", &json!({"text": "hi", "sha256": "abc"})), "hi\n[sha256 abc]");
    let out = text(
        "exec",
        &json!({"exit": 1, "stdout": "a\n", "stderr": "b\n", "truncated": false, "timed_out": false}),
    );
    assert_eq!(out, "exit 1\n--- stdout\na\n--- stderr\nb");
    assert!(text("exec", &json!({"exit": null, "timed_out": true})).starts_with("timed out"));
}
