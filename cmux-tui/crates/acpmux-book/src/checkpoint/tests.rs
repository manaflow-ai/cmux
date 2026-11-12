use super::*;
use crate::blobs::Blobs;
use crate::log::{Log, Options};

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn production_caps_fit_separate_checkpoint_budgets_and_roundtrip() -> TestResult {
    let home = tempfile::tempdir()?;
    let (mut log, _) = Log::open(home.path(), Options::default())?;
    let source = log.append_raw_file(b"test")?;
    let mut blobs = Blobs::open(home.path())?;
    let mut state = Checkpoint::new(5);
    state.last_row = 64;
    state.translator = vec![0; 32 * 1024];
    state.cursors.push(Cursor { file: source, place: 100, stamp: 7 });
    state.summary = vec![b'x'; 2048];
    state.prompts = vec![[42; 32]; 1024];
    let large = format!("\"{}\"", "x".repeat(1 << 20));
    for row in 1..=64 {
        let mut body = Body::new(row)?;
        blobs.set(&mut body, "text", &large, true)?;
        for key in ["content", "input", "entries", "source", "images", "title"] {
            blobs.set(&mut body, key, "null", false)?;
        }
        state.open.push(OpenBody { body, raw: RawRange { file: source, off: 1, len: 99 } });
    }
    blobs.sync(state.open.iter().map(|r| &r.body))?;
    let encoded = state.encode(state.open.len())?;
    let ids = state.open.iter().map(|r| r.body.row).collect::<Vec<_>>();
    state.write(&mut log, &ids)?;
    assert!(std::fs::metadata(home.path().join("checkpoint"))?.len() <= 96 * 1024);
    assert_eq!(Checkpoint::decode(&encoded)?, state);
    drop(log);
    let (_, recovered) = Log::open(home.path(), Options::default())?;
    assert_eq!(Checkpoint::decode(&recovered.state)?, state);
    // An inline body cannot consume spare queue room.
    for open in &mut state.open {
        open.body.spilled = false;
        open.body.fields.insert("text".into(), Value::Inline(vec![b'x'; 1024]));
    }
    assert!(matches!(state.encode(64), Err(Error::CheckpointTooLarge { .. })));
    Ok(())
}

#[test]
fn truncated_unknown_and_duplicate_sections_are_rejected() -> TestResult {
    let state = Checkpoint::new(5);
    let encoded = state.encode(0)?;
    for count in 0..encoded.len() {
        assert!(Checkpoint::decode(encoded.get(..count).ok_or("prefix missing")?).is_err());
    }
    let mut bad_version = encoded.clone();
    bad_version.get_mut(5..9).ok_or("version missing")?.copy_from_slice(&999u32.to_le_bytes());
    assert!(matches!(Checkpoint::decode(&bad_version), Err(Error::Rebuild(_))));
    let mut duplicate = encoded.clone();
    duplicate.extend_from_slice(&encoded);
    assert!(Checkpoint::decode(&duplicate).is_err());
    let mut trailing = encoded;
    trailing.push(0);
    assert!(Checkpoint::decode(&trailing).is_err());
    Ok(())
}

#[test]
fn edition_changes_only_when_translation_or_source_meaning_changes() -> TestResult {
    let mut state = Checkpoint::new(5);
    state.edition = 11;
    state.cursors.push(Cursor { file: 1, place: 90, stamp: 7 });
    let current = [Cursor { file: 1, place: 100, stamp: 7 }];
    assert_eq!(Checkpoint::rebuild_edition(Some(&state), Some(11), 5, &current, || 77)?, 11);
    assert_eq!(Checkpoint::rebuild_edition(Some(&state), Some(11), 6, &current, || 77)?, 12);
    assert_eq!(
        Checkpoint::rebuild_edition(
            Some(&state),
            Some(11),
            5,
            &[Cursor { stamp: 8, ..current.first().ok_or("cursor")?.clone() }],
            || 77
        )?,
        12
    );
    Ok(())
}

#[test]
fn readable_head_survives_an_unknown_or_damaged_body() -> TestResult {
    use crate::log::CheckpointHead;
    for unknown_version in [false, true] {
        let home = tempfile::tempdir()?;
        let (mut log, _) = Log::open(home.path(), Options::default())?;
        let mut state = Checkpoint::new(5);
        state.edition = 41;
        state.write(&mut log, &[])?;
        drop(log);
        let path = home.path().join("checkpoint");
        let mut bytes = std::fs::read(&path)?;
        if unknown_version {
            bytes.get_mut(4..8).ok_or("version missing")?.copy_from_slice(&999u32.to_le_bytes());
            let crc = crc32fast::hash(bytes.get(..12).ok_or("head missing")?);
            bytes.get_mut(12..16).ok_or("head crc missing")?.copy_from_slice(&crc.to_le_bytes());
        } else {
            *bytes.last_mut().ok_or("body crc missing")? ^= 1;
        }
        std::fs::write(path, bytes)?;
        let head = CheckpointHead::read(home.path())?.ok_or("head lost")?;
        assert_eq!(head.edition, 41);
        assert!(matches!(Log::open(home.path(), Options::default()), Err(Error::Rebuild(_))));
        assert_eq!(Checkpoint::rebuild_edition(None, Some(head.edition), 5, &[], || 77)?, 42);
    }
    Ok(())
}

#[test]
fn lost_heads_use_injected_editions_and_checkpointed_editions_survive_reopen() -> TestResult {
    use crate::log::CheckpointHead;
    let home = tempfile::tempdir()?;
    let mut editions = Vec::new();
    for random in [10, 20, 30] {
        let mut state = Checkpoint::new(5);
        state.edition = next_edition(None, || random);
        let dir = home.path().join(random.to_string());
        let (mut log, _) = Log::open(&dir, Options::default())?;
        state.write(&mut log, &[])?;
        drop(log);
        let (_, recovered) = Log::open(&dir, Options::default())?;
        assert_eq!(recovered.edition, state.edition);
        assert_eq!(Checkpoint::decode(&recovered.state)?.edition, state.edition);
        editions.push(state.edition);
        let path = dir.join("checkpoint");
        let mut bytes = std::fs::read(&path)?;
        *bytes.first_mut().ok_or("head missing")? ^= 1;
        std::fs::write(path, bytes)?;
        assert!(CheckpointHead::read(&dir)?.is_none());
    }
    assert_eq!(editions, vec![10, 20, 30]);
    assert_eq!(next_edition(Some(u32::MAX), || 99), 1);
    assert_ne!(next_edition(None, || 0), 0);
    Ok(())
}
