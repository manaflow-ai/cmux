use super::*;

#[test]
fn a_look_hands_back_one_picture_and_one_line() {
    let reply = json!({"image": {"mimeType": "image/png", "data": "AAAA"}, "width": 512, "height": 320, "tab": "t1", "movedBits": 12, "kept": 3});
    let out = answer(&reply);
    assert_eq!(out["content"][0]["type"], "image");
    assert_eq!(out["content"][0]["data"], "AAAA");
    let line = out["content"][1]["text"].as_str().unwrap();
    assert!(line.contains("12/64") && line.contains("frame 3"), "{line}");
}

#[test]
fn no_page_is_said_plainly() {
    let out = answer(&json!({"error": "no agent-driven page"}));
    assert_eq!(out["isError"], true);
}
