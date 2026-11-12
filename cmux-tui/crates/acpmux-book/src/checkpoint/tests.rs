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
        state.open.push(OpenBody { body, raw: RawRange { file: source, off: 1, len: 99 } });
    }
    blobs.sync(state.open.iter().map(|r| &r.body))?;
    let encoded = state.encode(state.open.len())?;
    let ids = state.open.iter().map(|r| r.body.row).collect::<Vec<_>>();
    log.write_checkpoint(&encoded, &ids)?;
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
    assert_eq!(Checkpoint::rebuild_edition(Some(&state), 5, &current)?, 11);
    assert_eq!(Checkpoint::rebuild_edition(Some(&state), 6, &current)?, 12);
    assert_eq!(
        Checkpoint::rebuild_edition(
            Some(&state),
            5,
            &[Cursor { stamp: 8, ..current.first().ok_or("cursor")?.clone() }]
        )?,
        12
    );
    Ok(())
}
