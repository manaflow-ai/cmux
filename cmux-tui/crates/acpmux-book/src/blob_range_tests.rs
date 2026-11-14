use super::*;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn whole_body(blobs: &Blobs, body: &Body) -> Result<Vec<u8>, Error> {
    let mut expected = Vec::new();
    blobs.write_body(body, &mut expected)?;
    Ok(expected)
}

fn check_ranges(blobs: &Blobs, body: &Body) -> TestResult {
    let expected = whole_body(blobs, body)?;
    assert_eq!(body.len(), expected.len() as u64);
    let mut out = Vec::new();
    for offset in 0..=expected.len().saturating_add(2) {
        for max in [0, 1, 2, 7, 31, usize::MAX] {
            let range = blobs.read_open_range(body, offset as u64, max, &mut out)?;
            let start = offset.min(expected.len());
            let end = start.saturating_add(max.min(MAX_BLOB_READ)).min(expected.len());
            assert_eq!(range.start, start as u64);
            assert_eq!(range.end, end as u64);
            assert_eq!(range.total, expected.len() as u64);
            assert_eq!(range.generation, body.generation);
            assert_eq!(out.as_slice(), expected.get(start..end).ok_or("range out of bounds")?);
        }
    }
    Ok(())
}

#[test]
fn open_ranges_match_stored_json_across_fields_and_escape_bytes() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(7)?;
    check_ranges(&blobs, &body)?;
    // The offset may cut a JSON escape or UTF-8 sequence. It is a stored byte range.
    blobs.set(&mut body, "text", "\"a\\n\\\"漢字\\u0000\"", false)?;
    blobs.set(&mut body, "content", "[1,true,{\"x\":null}]", false)?;
    blobs.set(&mut body, "title", "\"title\"", false)?;
    check_ranges(&blobs, &body)?;
    blobs.spill(&mut body)?;
    check_ranges(&blobs, &body)?;
    Ok(())
}

#[test]
fn open_range_caps_bytes_and_matches_the_settled_body() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(8)?;
    blobs.set(&mut body, "text", &format!("\"{}\"", "x".repeat(2 * MAX_BLOB_READ)), false)?;
    blobs.set(&mut body, "title", "\"end\"", false)?;
    assert!(body.spilled);
    assert!(blobs.settle(&body)?.is_none());
    let expected = fs::read(home.path().join("blobs/8"))?;
    let mut out = Vec::new();
    for (offset, max) in [(0, usize::MAX), (97, usize::MAX), (body.len() - 17, 256), (u64::MAX, 1)]
    {
        let range = blobs.read_open_range(&body, offset, max, &mut out)?;
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(expected.len());
        let end = start.saturating_add(max.min(MAX_BLOB_READ)).min(expected.len());
        assert_eq!(out.as_slice(), expected.get(start..end).ok_or("range out of bounds")?);
        assert_eq!(
            range,
            OpenBlobRange {
                start: start as u64,
                end: end as u64,
                total: expected.len() as u64,
                generation: body.generation,
            }
        );
        assert!(out.len() <= MAX_BLOB_READ);
    }
    Ok(())
}

#[test]
fn content_changes_advance_generation_without_renaming_appended_fields() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(9)?;
    let mut out = Vec::new();
    let initial = blobs.read_open_range(&body, 0, 100, &mut out)?.generation;
    blobs.set(&mut body, "text", "\"a\"", false)?;
    let first = blobs.read_open_range(&body, 0, 100, &mut out)?.generation;
    blobs.set(&mut body, "text", "\"b\"", true)?;
    let appended = blobs.read_open_range(&body, 0, 100, &mut out)?.generation;
    blobs.set(&mut body, "text", "\"cd\"", false)?;
    let replaced = blobs.read_open_range(&body, 0, 100, &mut out)?.generation;
    assert!(initial < first && first < appended && appended < replaced);
    blobs.spill(&mut body)?;
    let checkpoint = body.clone();
    let checkpoint_json = whole_body(&blobs, &checkpoint)?;
    let Some(Value::File(field)) = body.fields.get("text") else {
        return Err("not spilled".into());
    };
    let file_generation = field.generation;
    blobs.set(&mut body, "text", "\"ef\"", true)?;
    let range = blobs.read_open_range(&body, 0, 100, &mut out)?;
    assert!(range.generation > checkpoint.generation);
    assert_eq!(out, b"{\"text\":\"cdef\"}");
    let Some(Value::File(field)) = body.fields.get("text") else {
        return Err("not spilled".into());
    };
    assert_eq!(field.generation, file_generation);
    // A checkpoint still reads exactly its old file prefix and generation after an append.
    let old_range = blobs.read_open_range(&checkpoint, 0, 100, &mut out)?;
    assert_eq!(old_range.generation, checkpoint.generation);
    assert_eq!(out, checkpoint_json);
    blobs.set(&mut body, "text", "\"ghij\"", false)?;
    assert!(blobs.read_open_range(&body, 0, 100, &mut out)?.generation > range.generation);
    assert_eq!(out, b"{\"text\":\"ghij\"}");
    Ok(())
}

#[test]
fn range_reads_only_intersecting_files_and_refuses_short_fields() -> TestResult {
    let home = tempfile::tempdir()?;
    let mut blobs = Blobs::open(home.path())?;
    let mut body = Body::new(10)?;
    blobs.set(&mut body, "content", "[1,2,3]", false)?;
    blobs.set(&mut body, "text", "\"abcdef\"", false)?;
    blobs.spill(&mut body)?;
    let expected = whole_body(&blobs, &body)?;
    let Some(Value::File(content)) = body.fields.get("content") else {
        return Err("not spilled".into());
    };
    fs::remove_file(blobs.open.join(field_name(body.row, "content", content.generation)))?;
    let mut out = Vec::new();
    let offset = expected.len().saturating_sub(7);
    blobs.read_open_range(&body, offset as u64, 4, &mut out)?;
    assert_eq!(out.as_slice(), expected.get(offset..offset + 4).ok_or("range out of bounds")?);
    // No metadata call or open for the missing file unless its bytes are requested.
    blobs.read_open_range(&body, 0, 1, &mut out)?;
    assert_eq!(out, b"{");
    assert!(matches!(blobs.read_open_range(&body, 0, 100, &mut out), Err(Error::Corrupt(_))));
    let Some(Value::File(text)) = body.fields.get("text") else { return Err("not spilled".into()) };
    OpenOptions::new()
        .write(true)
        .open(blobs.open.join(field_name(body.row, "text", text.generation)))?
        .set_len(1)?;
    assert!(matches!(
        blobs.read_open_range(&body, offset as u64, 4, &mut out),
        Err(Error::Corrupt(_))
    ));
    // A stopped store is an error even for an empty read.
    assert!(blobs.recover(std::slice::from_ref(&body), body.row).is_err());
    assert!(matches!(blobs.read_open_range(&body, 0, 0, &mut out), Err(Error::Stopped)));
    Ok(())
}
