use super::*;

#[test]
fn a_senders_name_is_one_plain_file_name() {
    for (raw, want) in [
        ("shot.png", "shot.png"),
        ("../../etc/passwd", "passwd"),
        ("..\\..\\win.ini", "win.ini"),
        ("..", "attachment"),
        ("", "attachment"),
        (".bashrc", "bashrc"),
        ("a\u{202e}gnp.exe", "a_gnp.exe"),
        ("my shot ü.png", "my shot ü.png"),
        ("a\nb.txt", "a_b.txt"),
        ("trailing. ", "trailing"),
    ] {
        assert_eq!(safe_name(raw), want, "{raw:?}");
    }
    assert_eq!(safe_name(&"é".repeat(200)).len(), MAX_NAME_BYTES);
}

#[test]
fn small_files_go_inline_and_the_rest_by_reference() {
    assert!(fits_inline(&[2 << 20, 3 << 20], "look"));
    assert!(fits_inline(&[], &"x".repeat(1 << 20)));
    assert!(!fits_inline(&[INLINE_FILE_BYTES + 1], "big"));
    assert!(!fits_inline(&[1; INLINE_FILES + 1], "many"));
    assert!(!fits_inline(&[3 << 20, 3 << 20, 3 << 20, 3 << 20], "together"));
    assert!(!fits_inline(&[3 << 20], &"x".repeat(28 << 20)), "with its text");
    // Every message the senders put inline fits one JSON-RPC message.
    let most = [INLINE_TOTAL_BYTES / 4; 4];
    assert!(fits_inline(&most, "t"));
    let files: Vec<_> = most.iter().map(|&n| block("a.bin", &vec![0u8; n as usize])).collect();
    assert!(check_wire(&json!({"prompt": files})).is_ok());
}

#[test]
fn a_message_too_big_for_one_frame_is_refused() {
    // Two 11 MiB files fit below 31 MiB once encoded; the extra 2 MiB metadata pushes the
    // complete request over the transport limit.
    let half = vec![0u8; 11 << 20];
    let mut request = json!({"prompt": [block("a.bin", &half), block("b.bin", &half)]});
    assert!(check_wire(&request).is_ok());
    request["_meta"] = json!({"acpmux": {"promptId": "x".repeat(2 << 20)}});
    let refused = check_wire(&request).unwrap_err();
    assert!(refused.message.contains("31 MiB"), "{refused}");
}

#[tokio::test]
async fn a_held_message_keeps_its_files_until_it_is_dropped_or_its_release_never_ran() {
    let root = std::env::temp_dir().join(format!("acpmux-held-{}", uuid::Uuid::now_v7()));
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let held = |id: &str| {
        Err(RpcError::new(-32000, "held").with_data(json!({"held": true, "promptId": id})))
    };
    for (id, released) in [("dropped", false), ("released", true)] {
        let (dir, own) = (root.join(id), root.join(format!("{id}-upload")));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(&own).unwrap();
        let saved = Saved::new("s", vec![own.clone()]).in_dir(dir.clone());
        saved.settle(&hub, &held(id)).await;
        assert!(dir.is_dir(), "{id}: kept while held");
        assert!(own.is_dir(), "{id}: its own upload kept while held");
        if released {
            // Released, then withdrawn from the queue: its run never came.
            held_released(&hub, "s", id).await;
        } else {
            held_dropped("s", id);
            for _ in 0..100 {
                if !dir.exists() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }
        assert!(!dir.exists(), "{id}");
        assert!(!own.exists(), "{id}: its own upload");
    }
    let _ = std::fs::remove_dir_all(root);
}

/// A prompt the session took and that then never ran (withdrawn from its queue, or refused
/// when its turn came) deletes the uploads it named as its own; one that ran keeps them.
#[tokio::test]
async fn a_taken_prompt_that_never_ran_leaves_none_of_its_own_uploads() {
    let root = std::env::temp_dir().join(format!("acpmux-owned-{}", uuid::Uuid::now_v7()));
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let withdrawn = Ok(json!({"_meta": {"acpmux": {"withdrawn": true}}}));
    let refused = Err(RpcError::new(-32000, "refused when its turn came"));
    for (id, queued, answer, kept) in [
        ("withdrawn", true, withdrawn, false),
        ("refused", true, refused, false),
        ("ran", false, Ok(json!({"stopReason": "end_turn"})), true),
    ] {
        let own = root.join(id);
        std::fs::create_dir_all(&own).unwrap();
        let saved = Saved::new("s", vec![own.clone()]);
        let accepted = saved.watch(None).unwrap();
        accepted(json!({"queued": queued, "promptId": id}));
        saved.settle(&hub, &answer).await;
        assert_eq!(own.is_dir(), kept, "{id}");
    }
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn files_of_a_message_dropped_unanswered_are_deleted() {
    let root = std::env::temp_dir().join(format!("acpmux-saved-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    drop(Saved::new("", Vec::new()).in_dir(root.clone()));
    assert!(!root.exists());
}
