use super::*;

/// Two pushes of the chat settings may save at once (an off push still ending agents and an
/// unset push after it): every save succeeds, and the file holds one of them whole.
#[test]
fn saves_at_once_all_succeed() {
    let dir = std::env::temp_dir().join(format!("acpmux-chat-settings-{}", std::process::id()));
    let path = dir.join("chat-settings.json");
    let failed: Vec<String> = std::thread::scope(|scope| {
        let saves: Vec<_> = (0..8)
            .map(|i| {
                let path = &path;
                scope.spawn(move || {
                    let settings = ChatSettings { enabled: i % 2 == 0, ..Default::default() };
                    (0..100)
                        .filter_map(|_| settings.save(path).err())
                        .map(|e| e.to_string())
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        saves.into_iter().flat_map(|s| s.join().unwrap()).collect()
    });
    let saved = fs::read(&path).map(|b| serde_json::from_slice::<ChatSettings>(&b).is_ok());
    let left: Vec<_> = fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name()).collect();
    let _ = fs::remove_dir_all(&dir);
    assert!(failed.is_empty(), "saves at once failed: {failed:?}");
    assert_eq!(saved.ok(), Some(true), "the file does not hold one save whole");
    assert_eq!(left.len(), 1, "temp files were left: {left:?}");
}
