use super::*;

#[test]
fn a_look_hands_back_one_picture_and_one_line() {
    let reply = json!({"image": {"mimeType": "image/png", "data": "AAAA"}, "width": 512, "height": 320, "tab": "t1", "url": "http://localhost:5173/settings", "movedBits": 12, "kept": 3});
    let out = answer(&reply);
    assert_eq!(out["content"][0]["type"], "image");
    assert_eq!(out["content"][0]["data"], "AAAA");
    let line = out["content"][1]["text"].as_str().unwrap();
    assert!(line.contains("12/64") && line.contains("frame 3"), "{line}");
    assert!(line.contains("http://localhost:5173/settings"), "{line}");
    assert!(line.contains("tab t1"), "{line}");
}

#[test]
fn a_window_or_older_daemon_without_a_url_still_answers() {
    let out = answer(&json!({"image": {"mimeType": "image/png", "data": "AAAA"},
        "width": 512, "height": 320, "tab": "window", "movedBits": 0}));
    assert_eq!(out["isError"], false);
    assert!(out["content"][1]["text"].as_str().unwrap().contains("window"));
}

#[test]
fn no_page_is_said_plainly() {
    let out = answer(&json!({"error": "no agent-driven page"}));
    assert_eq!(out["isError"], true);
}
