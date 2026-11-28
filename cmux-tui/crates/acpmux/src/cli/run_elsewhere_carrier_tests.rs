use super::*;
use std::path::Path;

#[test]
fn the_script_goes_to_the_far_temp_folder_named_for_its_run() {
    let far = far_path(Path::new("/home/me/.acpmux/run-elsewhere/0192abcd.sh")).unwrap();
    assert_eq!(far, "/tmp/cmux-run-elsewhere-0192abcd.sh");
    assert!(far_path(Path::new("/x/../evil name.sh")).is_err());
    assert!(far_path(Path::new("/x/a;b.sh")).is_err());
}

#[test]
fn the_patch_is_written_then_run_and_removes_itself_first() {
    let [write, exec] = calls("cloud-a", "/tmp/cmux-run-elsewhere-r1.sh", "set -eu\necho hi\n");
    assert_eq!(write["machine"], "cloud-a");
    assert_eq!(write["action"], "fs.write");
    assert_eq!(write["params"]["path"], "/tmp/cmux-run-elsewhere-r1.sh");
    let text = write["params"]["text"].as_str().unwrap();
    assert!(text.starts_with("rm -f -- \"$0\"\nset -eu\n"), "{text}");
    assert_eq!(exec["action"], "exec");
    assert_eq!(exec["params"]["argv"], json!(["/bin/bash", "/tmp/cmux-run-elsewhere-r1.sh"]));
    assert_eq!(exec["params"]["timeout_ms"], 600_000);
    // Both pass the relay's own checks.
    for call in [&write, &exec] {
        crate::machine_files::parse(call).unwrap();
    }
}

#[test]
fn the_exit_code_and_end_come_from_the_far_answer() {
    assert_eq!(outcome(&json!({"exit": 3})), (3, None));
    let (code, note) = outcome(&json!({"exit": 0, "truncated": true}));
    assert_eq!(code, 0);
    assert!(note.unwrap().contains("256 KB"));
    assert_eq!(outcome(&json!({"timed_out": true})).0, 124);
    assert_eq!(outcome(&json!({})).0, 137);
}
