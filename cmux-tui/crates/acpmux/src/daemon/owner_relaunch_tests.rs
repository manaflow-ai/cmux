use super::*;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("owner-relaunch-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A marker written names the time left and why; cleared, it names nothing.
#[test]
fn update_handoff_a_marker_holds_until_cleared() {
    let dir = scratch("holds");
    assert!(left_in(&dir).is_none());
    expect_in(&dir, Duration::from_secs(30), "an update").unwrap();
    let (left, why) = left_in(&dir).expect("the marker holds");
    assert!(left <= Duration::from_secs(30) && left > Duration::from_secs(25), "{left:?}");
    assert_eq!(why, "an update");
    clear_in(&dir);
    assert!(left_in(&dir).is_none());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A marker cannot ask more than MAX_WITHIN, and one past its deadline is ignored.
#[test]
fn update_handoff_a_marker_is_capped_and_expires() {
    let dir = scratch("cap");
    expect_in(&dir, Duration::from_secs(10_000), "x").unwrap();
    assert!(left_in(&dir).unwrap().0 <= MAX_WITHIN);
    std::fs::write(path_in(&dir), r#"{"untilMs": 1, "reason": "old"}"#).unwrap();
    assert!(left_in(&dir).is_none());
    std::fs::write(path_in(&dir), "not json").unwrap();
    assert!(left_in(&dir).is_none());
    let _ = std::fs::remove_dir_all(&dir);
}
