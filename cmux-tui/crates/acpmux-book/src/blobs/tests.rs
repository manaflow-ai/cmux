use super::*;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn bytes(blobs: &Blobs, body: &Body) -> Result<Vec<u8>, Error> {
    let mut bytes = Vec::new();
    blobs.write_body(body, &mut bytes)?;
    Ok(bytes)
}

#[test]
fn replacement_and_settle_leave_checkpoint_values_until_recovery() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(7)?;
    let first = format!("\"{}\"", "a".repeat(1 << 20));
    blobs.set(&mut body, "content", &first, false)?;
    blobs.set(&mut body, "text", "\"one\\n\"", true)?;
    assert!(body.spilled);
    blobs.sync([&body])?;
    let checkpoint = body.clone();
    let original = bytes(&blobs, &checkpoint)?;
    for step in 0..4 {
        body = checkpoint.clone();
        if step >= 1 {
            blobs.set(&mut body, "text", "\"two\\\"\"", true)?;
        }
        if step >= 2 {
            blobs.set(&mut body, "content", "{\"replacement\":true}", false)?;
        }
        if step >= 3 {
            assert!(blobs.settle(&body)?.is_some());
        }
        // A kill leaves the old checkpoint owning its files; reopen restores that view.
        drop(blobs);
        blobs = Blobs::open(home.path())?;
        blobs.recover(std::slice::from_ref(&checkpoint), 7)?;
        assert_eq!(bytes(&blobs, &checkpoint)?, original);
    }
    body = checkpoint.clone();
    blobs.set(&mut body, "content", "{\"replacement\":true}", false)?;
    let settled = blobs.settle(&body)?.ok_or("small body did not return inline")?;
    assert_eq!(settled, b"{\"content\":{\"replacement\":true},\"text\":\"one\\n\"}");
    assert_eq!(bytes(&blobs, &checkpoint)?, original, "settle must keep checkpoint files");
    // The checkpoint no longer names the settled row; cleanup may now reclaim its files.
    blobs.recover(&[], 7)?;
    assert_eq!(fs::read_dir(home.path().join("blobs/open"))?.count(), 0);
    Ok(())
}

#[test]
fn large_settle_is_replayed_and_old_out_of_order_blobs_are_removed() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(3)?;
    let large = format!("\"{}\"", "x".repeat(1 << 20));
    blobs.set(&mut body, "text", &large, true)?;
    blobs.sync([&body])?;
    let checkpoint = body.clone();
    blobs.set(&mut body, "text", "\"suffix\"", true)?;
    assert!(blobs.settle(&body)?.is_none());
    let expected = fs::read(home.path().join("blobs/3"))?;
    assert_eq!(expected, bytes(&blobs, &body)?);
    drop(blobs);
    blobs = Blobs::open(home.path())?;
    // Row 3 was still open even though row 100 existed at the checkpoint.
    blobs.recover(std::slice::from_ref(&checkpoint), 100)?;
    assert!(!home.path().join("blobs/3").exists());
    body = checkpoint;
    blobs.set(&mut body, "text", "\"suffix\"", true)?;
    blobs.settle(&body)?;
    assert_eq!(fs::read(home.path().join("blobs/3"))?, expected);
    blobs.recover(&[], 100)?;
    assert_eq!(fs::read(home.path().join("blobs/3"))?, expected);
    assert_eq!(fs::read_dir(home.path().join("blobs/open"))?.count(), 0);
    Ok(())
}

#[test]
fn spill_and_inline_share_fixed_order_and_escaped_text() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(1)?;
    blobs.set(&mut body, "text", "\"a\\n\"", true)?;
    blobs.set(&mut body, "title", "\"title\"", false)?;
    blobs.set(&mut body, "content", "[1,true]", false)?;
    let original = bytes(&blobs, &body)?;
    blobs.spill(&mut body)?;
    assert_eq!(original, bytes(&blobs, &body)?);
    blobs.set(&mut body, "text", "\"\\\"漢字\"", true)?;
    assert_eq!(
        bytes(&blobs, &body)?,
        "{\"content\":[1,true],\"text\":\"a\\n\\\"漢字\",\"title\":\"title\"}".as_bytes()
    );
    assert!(blobs.set(&mut body, "../escape", "0", false).is_err());
    assert!(blobs.set(&mut body, "content", "0", true).is_err());
    Ok(())
}

#[test]
fn short_checkpoint_field_is_damage_and_stops_the_store() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(1)?;
    blobs.set(&mut body, "text", "\"abc\"", true)?;
    blobs.spill(&mut body)?;
    blobs.sync([&body])?;
    let field = body.fields.get("text").ok_or("text missing")?;
    let Value::File(field) = field else { return Err("text not spilled".into()) };
    OpenOptions::new()
        .write(true)
        .open(blobs.open.join(field_name(1, "text", field.generation)))?
        .set_len(2)?;
    assert!(matches!(blobs.recover(&[body], 1), Err(Error::Corrupt(_))));
    assert!(matches!(blobs.sync([]), Err(Error::Stopped)));
    Ok(())
}
