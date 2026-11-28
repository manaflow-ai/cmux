use super::*;
use std::io::Write;

// The leading decimal is the test source's seq, with arbitrary gaps.
fn seq_places(line: &[u8], _: u64) -> io::Result<Range<u64>> {
    let seq = line.split(|byte| *byte == b' ').next().ok_or_else(|| invalid("missing seq"))?;
    let start: u64 = std::str::from_utf8(seq)
        .map_err(io::Error::other)?
        .parse()
        .map_err(io::Error::other)?;
    Ok(start..start.checked_add(1).ok_or_else(|| invalid("seq overflow"))?)
}

struct GappedSource {
    bytes: Vec<u8>,
    stamp: u64,
    synced: u64,
}
impl RawSource for GappedSource {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        let mut bytes = Vec::with_capacity(CHUNK_BYTES);
        let mut at_end = true;
        for line in self.bytes.split_inclusive(|byte| *byte == b'\n') {
            if seq_places(line, 0)?.start < place {
                continue;
            }
            if !bytes.is_empty() && bytes.len() + line.len() > CHUNK_BYTES {
                at_end = false;
                break;
            }
            bytes.extend_from_slice(line);
        }
        Ok(Chunk::with_stamp(bytes, 0, seq_places, at_end, self.hint()?, self.stamp))
    }
    fn hint(&self) -> io::Result<u64> {
        self.bytes
            .split_inclusive(|byte| *byte == b'\n')
            .next_back()
            .map(|line| seq_places(line, 0).map(|range| range.end))
            .unwrap_or(Ok(0))
    }
    fn holds(&mut self, place: u64) -> io::Result<bool> {
        Ok(place <= self.hint()?)
    }
    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        if !self.holds(place)? {
            return Err(invalid("sync past end"));
        }
        self.synced = self.synced.max(place);
        Ok(())
    }
    fn identity(&self) -> &[u8] {
        b"test:gapped"
    }
    fn stamp(&self) -> u64 {
        self.stamp
    }
}

#[test]
fn gapped_places_keep_the_same_lines_in_one_buffer() -> io::Result<()> {
    let bytes = b"100 one\n900 two\n9000 three\n";
    let mut raw = tempfile::NamedTempFile::new()?;
    raw.write_all(bytes)?;
    let mut file = FileSource::open(raw.path())?;
    let mut gaps = GappedSource { bytes: bytes.to_vec(), stamp: 1, synced: 0 };
    let chunk = gaps.read_chunk(0)?;
    chunk.validate(0)?;
    assert_eq!(file.read_chunk(0)?.bytes(), chunk.bytes());
    let mut lines = chunk.lines();
    assert_eq!(lines.next().ok_or_else(|| invalid("missing line"))??.start, 100);
    assert_eq!(lines.next().ok_or_else(|| invalid("missing line"))??.end, 901);
    assert_eq!(file.read_chunk(8)?.bytes(), gaps.read_chunk(101)?.bytes());
    assert_eq!(gaps.hint()?, 9001);
    gaps.sync_through(901)?;
    assert_eq!(gaps.synced, 901);
    assert!(chunk.validate(101).is_err());
    Ok(())
}

#[test]
fn a_large_line_yields_between_bounded_scans() -> io::Result<()> {
    let mut raw = tempfile::NamedTempFile::new()?;
    raw.write_all(&vec![b'x'; CHUNK_BYTES * 3])?;
    raw.write_all(b"\npartial")?;
    let mut source = FileSource::open(raw.path())?;
    assert_eq!(source.stats().bytes, 0);
    for _ in 0..3 {
        let chunk = source.read_chunk(0)?;
        assert!(!chunk.at_end);
        assert!(chunk.bytes().is_empty());
    }
    let large = source.read_chunk(0)?;
    large.validate(0)?;
    assert_eq!(large.lines().count(), 1);
    let cursor = CHUNK_BYTES as u64 * 3 + 1;
    assert!(source.holds(cursor)?);
    assert!(!source.holds(cursor + 1)?);
    let partial = source.read_chunk(cursor)?;
    assert!(partial.at_end && partial.bytes().is_empty());
    raw.write_all(b"\n")?;
    assert_eq!(source.read_chunk(cursor)?.bytes(), b"partial\n");
    Ok(())
}

#[test]
fn long_partial_append_scans_each_byte_once() -> io::Result<()> {
    let mut raw = tempfile::NamedTempFile::new()?;
    let mut source = FileSource::open(raw.path())?;
    let piece = vec![b'x'; 100_000];
    for _ in 0..100 {
        raw.write_all(&piece)?;
        let chunk = source.read_chunk(0)?;
        assert!(chunk.at_end && chunk.bytes().is_empty());
    }
    assert_eq!(source.stats().scanned, 10_000_000);
    raw.write_all(b"\n")?;
    let chunk = source.read_chunk(0)?;
    assert!(chunk.at_end);
    assert_eq!(chunk.bytes().len(), 10_000_001);
    assert_eq!(source.stats().scanned, 10_000_001);
    assert!(source.read_chunk(10_000_001)?.bytes().is_empty());
    Ok(())
}

#[test]
fn a_gigabyte_growth_costs_one_chunk_and_holds_one_byte() -> io::Result<()> {
    let mut raw = tempfile::NamedTempFile::new()?;
    raw.write_all(b"a\n")?;
    let mut source = FileSource::open(raw.path())?;
    assert!(source.read_chunk(0)?.at_end);
    // Sparse history: only the next chunk is relevant to this call's budget.
    raw.write_all(&vec![b'\n'; CHUNK_BYTES])?;
    raw.as_file().set_len(1 << 30)?;
    let before = source.stats();
    let chunk = source.read_chunk(2)?;
    assert_eq!(chunk.bytes().len(), CHUNK_BYTES);
    assert!(!chunk.at_end);
    assert_eq!(source.stats().bytes - before.bytes, CHUNK_BYTES as u64);
    let before = source.stats();
    assert!(source.holds(2)?);
    assert_eq!(source.stats().bytes - before.bytes, 1);
    Ok(())
}

#[test]
fn follow_generation_accepts_append_and_counts_oversized_lines() -> io::Result<()> {
    let mut raw = tempfile::NamedTempFile::new()?;
    raw.write_all(b"header\n")?;
    let mut source = FollowFileSource::open(raw.path())?;
    assert_eq!(source.read_chunk(0)?.bytes(), b"header\n");
    let before = source.generation();
    raw.write_all(b"tail\n")?;
    assert_eq!(source.check_generation()?, GenerationChange::Appended { size: 12 });
    assert_eq!(source.generation().dev, before.dev);
    assert_eq!(source.generation().ino, before.ino);
    assert_eq!(source.read_chunk(7)?.bytes(), b"tail\n");

    let mut large = tempfile::NamedTempFile::new()?;
    large.write_all(&vec![b'x'; CHUNK_BYTES * 2])?;
    large.write_all(b"\n")?;
    let mut large_source = FollowFileSource::open(large.path())?;
    assert_eq!(large_source.stats().oversized_lines, 0);
    let mut chunk = large_source.read_chunk(0)?;
    assert!(chunk.bytes().is_empty());
    chunk = large_source.read_chunk(0)?;
    assert!(chunk.bytes().is_empty());
    chunk = large_source.read_chunk(0)?;
    assert_eq!(chunk.lines().count(), 1);
    assert_eq!(large_source.stats().oversized_lines, 1);
    assert_eq!(large_source.stats().oversized_bytes, (CHUNK_BYTES * 2 + 1) as u64);
    Ok(())
}

#[test]
fn follow_generation_rejects_replace_shrink_and_head_rewrite() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("transcript.jsonl");
    std::fs::write(&path, b"header\nbody\n")?;
    let mut source = FollowFileSource::open(&path)?;
    std::fs::write(&path, b"header\n")?;
    assert_eq!(source.check_generation()?, GenerationChange::Replaced);

    std::fs::write(&path, b"header\nbody\n")?;
    let mut source = FollowFileSource::open(&path)?;
    std::fs::write(&path, b"head")?;
    assert_eq!(source.check_generation()?, GenerationChange::Replaced);

    std::fs::write(&path, b"header\nbody\n")?;
    let mut source = FollowFileSource::open(&path)?;
    let replacement = dir.path().join("replacement.jsonl");
    std::fs::write(&replacement, b"other\nbody\n")?;
    std::fs::rename(replacement, &path)?;
    assert_eq!(source.check_generation()?, GenerationChange::Replaced);

    std::fs::write(&path, b"header\nbody\n")?;
    let mut source = FollowFileSource::open(&path)?;
    let mut file = OpenOptions::new().write(true).open(&path)?;
    file.write_all(b"changed")?;
    file.sync_all()?;
    assert_eq!(source.check_generation()?, GenerationChange::Rewritten);
    Ok(())
}

#[test]
fn tiny_lines_need_no_per_line_allocation() -> io::Result<()> {
    let chunk = Chunk::new(vec![b'\n'; CHUNK_BYTES], 0, byte_places, true, CHUNK_BYTES as u64);
    chunk.validate(0)?;
    assert_eq!(chunk.lines().count(), CHUNK_BYTES);
    assert_eq!(chunk.resident_bytes(), CHUNK_BYTES);
    Ok(())
}

#[test]
fn raw_map_is_synced_before_the_first_record_and_receipts_are_ordered() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let map_path = dir.path().join("raw.map");
    let raw_path = dir.path().join("raw").join("events.ndjson");
    std::fs::create_dir_all(raw_path.parent().ok_or_else(|| invalid("raw parent"))?)?;
    let mut map = RawMap::open(&map_path)?;
    let index_path = dir.path().join("raw.idx");
    let (source, mut writer) =
        RawWriter::open_mapped(&mut map, &raw_path, b"file:test", Some(&index_path), 41)?;
    assert_eq!(source, 0);
    let receipt = writer.append(
        br#"{"seq":41,"at":99,"dir":"in","kind":"message","msg":{"text":"hi"},"hostSeq":7}"#,
        true,
    )?;
    assert_eq!(receipt.seq, 41);
    assert!(receipt.synced);
    let map_line = std::fs::read_to_string(&map_path)?;
    let raw_line = std::fs::read_to_string(&raw_path)?;
    assert!(map_line.contains("file:test"));
    assert!(raw_line.contains("\"seq\":41"));
    assert!(raw_line.ends_with('\n'));
    assert!(index_path.exists());
    Ok(())
}

#[test]
fn raw_writer_repairs_a_torn_tail_without_reading_the_whole_file() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    std::fs::write(&raw, b"{\"seq\":1}\npartial")?;
    let mut writer = RawWriter::open(&raw, 2)?;
    let receipt =
        writer.append(br#"{"seq":2,"at":100,"dir":"mux","kind":"notice","msg":{}}"#, true)?;
    assert_eq!(receipt.seq, 2);
    let bytes = std::fs::read(&raw)?;
    assert!(!bytes.windows(b"partial".len()).any(|window| window == b"partial"));
    assert!(bytes.ends_with(b"\n"));
    Ok(())
}

#[test]
fn raw_writer_cuts_a_torn_first_line_to_zero() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    std::fs::write(&raw, b"never-acked")?;
    let mut writer = RawWriter::open(&raw, 0)?;
    assert_eq!(std::fs::read(&raw)?, b"");
    writer.append(br#"{"seq":0}"#, true)?;
    assert!(std::fs::read(&raw)?.ends_with(b"\n"));
    Ok(())
}

#[test]
fn raw_writer_allows_a_line_larger_than_one_repair_block() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    let mut writer = RawWriter::open(&raw, 0)?;
    let line = vec![b'x'; REPAIR_BLOCK_BYTES as usize * 2 + 17];
    let receipt = writer.append(&line, true)?;
    assert_eq!(receipt.end, line.len() as u64 + 1);
    Ok(())
}

#[test]
fn failed_raw_write_rolls_back_and_poison_requires_reopen() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    let line = br#"{"seq":9,"msg":"partial"}"#;
    for fail_at in 0..=line.len() {
        std::fs::write(&raw, b"previous\n")?;
        let mut writer = RawWriter::open(&raw, 9)?;
        writer.fail_after(fail_at);
        assert!(writer.append(line, true).is_err());
        assert_eq!(std::fs::read(&raw)?, b"previous\n");
        assert!(writer.append(line, true).is_err());
        assert!(writer.sync().is_err());
        drop(writer);
        let mut reopened = RawWriter::open(&raw, 9)?;
        assert_eq!(reopened.append(line, true)?.seq, 9);
    }
    Ok(())
}

#[test]
fn repair_walks_multiple_blocks_and_cuts_any_torn_first_line() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    for prefix in [b"".as_slice(), b"complete\n".as_slice()] {
        let mut file = File::create(&raw)?;
        file.write_all(prefix)?;
        file.write_all(&vec![b'x'; REPAIR_BLOCK_BYTES as usize * 3 + 17])?;
        drop(file);
        let _writer = RawWriter::open(&raw, 9)?;
        assert_eq!(std::fs::read(&raw)?, prefix);
    }
    Ok(())
}

#[test]
fn index_repairs_torn_entry_and_reopen_keeps_mark_origin() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    let index = dir.path().join("events.idx");
    let live_raw = dir.path().join("live.ndjson");
    let live_index = dir.path().join("live.idx");
    let mut writer = RawWriter::open_with_index(&raw, Some(&index), 0)?;
    let mut live = RawWriter::open_with_index(&live_raw, Some(&live_index), 0)?;
    let line = vec![b'x'; REPAIR_BLOCK_BYTES as usize];
    writer.append(&line, true)?;
    live.append(&line, true)?;
    assert_eq!(std::fs::metadata(&index)?.len(), 16);
    drop(writer);
    OpenOptions::new().append(true).open(&index)?.write_all(&[1, 2, 3])?;
    let mut reopened = RawWriter::open_with_index(&raw, Some(&index), 1)?;
    assert_eq!(std::fs::metadata(&index)?.len(), 16);
    for body in [b"small".as_slice(), line.as_slice(), b"last".as_slice()] {
        assert_eq!(reopened.append(body, true)?, live.append(body, true)?);
    }
    assert_eq!(std::fs::read(&index)?, std::fs::read(&live_index)?);
    drop(reopened);
    // A complete index mark for an unacknowledged, torn raw record is discarded too.
    let length = std::fs::metadata(&raw)?.len();
    let mut index_file = OpenOptions::new().append(true).open(&index)?;
    index_file.write_all(&4u64.to_le_bytes())?;
    index_file.write_all(&length.to_le_bytes())?;
    OpenOptions::new().append(true).open(&raw)?.write_all(b"torn")?;
    let _reopened = RawWriter::open_with_index(&raw, Some(&index), 4)?;
    assert_eq!(std::fs::read(&index)?, std::fs::read(&live_index)?);
    Ok(())
}

#[test]
fn raw_map_repairs_and_reuses_the_existing_last_source() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let map_path = dir.path().join("raw.map");
    let raw_path = dir.path().join("events.ndjson");
    let mut map = RawMap::open(&map_path)?;
    assert_eq!(map.append_file(&raw_path, b"file:test")?, 0);
    let length = std::fs::metadata(&map_path)?.len();
    OpenOptions::new().append(true).open(&map_path)?.write_all(b"torn")?;
    let mut reopened = RawMap::open(&map_path)?;
    assert_eq!(std::fs::metadata(&map_path)?.len(), length);
    assert_eq!(reopened.append_file(&raw_path, b"file:test")?, 0);
    let (first, writer) =
        RawWriter::open_mapped(&mut reopened, &raw_path, b"file:test", None, 4)?;
    drop(writer);
    let (again, _writer) =
        RawWriter::open_mapped(&mut reopened, &raw_path, b"file:test", None, 4)?;
    assert_eq!((first, again), (0, 0));
    assert_eq!(std::fs::metadata(&map_path)?.len(), length);
    let second_path = dir.path().join("other.ndjson");
    assert_eq!(reopened.append_file(&second_path, b"file:second")?, 1);
    drop(reopened);
    let mut reopened = RawMap::open(&map_path)?;
    assert_eq!(reopened.append_file(&raw_path, b"file:test")?, 0);
    assert_eq!(reopened.append_file(&dir.path().join("third"), b"file:third")?, 2);
    Ok(())
}

#[test]
fn raw_map_finds_an_entry_without_reading_its_file() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let map_path = dir.path().join("raw.map");
    let mut map = RawMap::open(&map_path)?;
    for (n, name) in ["first", "second", "third"].into_iter().enumerate() {
        let path = dir.path().join(name);
        assert_eq!(map.append_file(&path, name.as_bytes())?, n as u32);
    }
    // The lookup is in memory: with the file emptied under it, the first entry is still
    // found and nothing is written.
    OpenOptions::new().write(true).open(&map_path)?.set_len(0)?;
    assert_eq!(map.append_file(&dir.path().join("first"), b"first")?, 0);
    assert_eq!(std::fs::metadata(&map_path)?.len(), 0);
    Ok(())
}

#[test]
fn raw_map_cuts_an_invalid_last_line_and_keeps_every_earlier_entry() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let map_path = dir.path().join("raw.map");
    let mut map = RawMap::open(&map_path)?;
    assert_eq!(map.append_file(&dir.path().join("a"), b"file:a")?, 0);
    assert_eq!(map.append_file(&dir.path().join("b"), b"file:b")?, 1);
    drop(map);
    let length = std::fs::metadata(&map_path)?.len();
    // A whole last line that is not an entry, as a kill mid-write can leave.
    OpenOptions::new().append(true).open(&map_path)?.write_all(b"{\"source\":2,\"pa\n")?;
    let mut reopened = RawMap::open(&map_path)?;
    assert_eq!(std::fs::metadata(&map_path)?.len(), length);
    assert_eq!(reopened.append_file(&dir.path().join("a"), b"file:a")?, 0);
    assert_eq!(reopened.append_file(&dir.path().join("b"), b"file:b")?, 1);
    assert_eq!(reopened.append_file(&dir.path().join("c"), b"file:c")?, 2);
    drop(reopened);
    // An invalid line before the last is not a torn write: the open fails.
    let mut bytes = b"not an entry\n".to_vec();
    bytes.extend_from_slice(&std::fs::read(&map_path)?);
    std::fs::write(&map_path, &bytes)?;
    assert!(RawMap::open(&map_path).is_err());
    assert_eq!(std::fs::read(&map_path)?, bytes);
    Ok(())
}

#[test]
fn raw_writer_keeps_its_index_length_and_rolls_it_back() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    let index = dir.path().join("events.idx");
    let mut writer = RawWriter::open_with_index(&raw, Some(&index), 0)?;
    let line = vec![b'x'; RAW_INDEX_BYTES as usize];
    writer.append(&line, true)?;
    assert_eq!(writer.index_len, 16);
    assert_eq!(std::fs::metadata(&index)?.len(), 16);
    // Bytes the writer did not write: a failed append cuts the index back to the length it
    // keeps, not to the length the file system reports at that append.
    OpenOptions::new().append(true).open(&index)?.write_all(&[7; 16])?;
    writer.fail_after(3);
    assert!(writer.append(&line, true).is_err());
    assert_eq!(writer.index_len, 16);
    assert_eq!(std::fs::metadata(&index)?.len(), 16);
    Ok(())
}

#[test]
fn index_rebuilds_the_marks_a_kill_left_out() -> io::Result<()> {
    let dir = tempfile::tempdir()?;
    let live_raw = dir.path().join("live.ndjson");
    let live_index = dir.path().join("live.idx");
    let mut live = RawWriter::open_with_index(&live_raw, Some(&live_index), 5)?;
    let line = vec![b'x'; 100_000];
    for _ in 0..12 {
        live.append(&line, false)?;
    }
    live.append(&vec![b'y'; RAW_INDEX_BYTES as usize * 2], false)?;
    live.append(b"short", true)?;
    drop(live);
    let marks = std::fs::read(&live_index)?;
    assert!(marks.len() >= 16 * 4);
    let raw = dir.path().join("events.ndjson");
    let index = dir.path().join("events.idx");
    std::fs::copy(&live_raw, &raw)?;
    // The index lost its last marks, then lost a torn half mark, then lost every mark.
    let cuts = [16usize, 16 + 7, 0];
    for cut in cuts {
        std::fs::write(&index, marks.get(..cut).ok_or_else(|| invalid("cut"))?)?;
        let _writer = RawWriter::open_with_index(&raw, Some(&index), 19)?;
        assert_eq!(std::fs::read(&index)?, marks, "index cut to {cut} bytes");
    }
    // A whole index reads nothing more and writes nothing.
    let _writer = RawWriter::open_with_index(&raw, Some(&index), 19)?;
    assert_eq!(std::fs::read(&index)?, marks);
    Ok(())
}

#[test]
#[ignore = "release gate: bounded source reads at both history sizes"]
fn v2_pr03a_source_read_bounds() -> io::Result<()> {
    let mut measured = Vec::new();
    for rows in [40u64, 2_000_000] {
        let mut raw = tempfile::NamedTempFile::new()?;
        let cursor = rows * 80;
        raw.seek(SeekFrom::Start(cursor - 1))?;
        raw.write_all(b"\n")?;
        let mut source = FileSource::open(raw.path())?;
        assert!(source.read_chunk(cursor)?.at_end);
        raw.write_all(&vec![b'\n'; CHUNK_BYTES])?;
        raw.as_file().set_len(cursor + (1 << 30))?;
        let before = source.stats();
        let chunk = source.read_chunk(cursor)?;
        let read = source.stats().bytes - before.bytes;
        assert_eq!(chunk.bytes().len(), CHUNK_BYTES);
        assert!(!chunk.at_end);
        assert!(read <= CHUNK_BYTES as u64);
        let before = source.stats();
        assert!(source.holds(cursor)?);
        let holds = source.stats().bytes - before.bytes;
        assert_eq!(holds, 1);
        measured.push((read, holds));
        eprintln!(
            "v2.pr03a.source_read_bounds rows={rows} appended_bytes=1073741824 read_bytes={read} holds_bytes={holds}"
        );
    }
    let small = measured.first().ok_or_else(|| invalid("small measurement"))?;
    let god = measured.last().ok_or_else(|| invalid("god measurement"))?;
    eprintln!(
        "v2.pr03a.source_read_bounds read_ratio={} holds_ratio={}",
        god.0 as f64 / small.0 as f64,
        god.1 as f64 / small.1 as f64
    );
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        let mut output = OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(
            output,
            "{{\"name\":\"v2.pr03a.source_read_bounds\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"bytes\"}}",
            small.0, god.0
        )?;
    }
    // The bound after the line: a red row keeps its numbers in the v2 home.
    assert_eq!(small, god);
    Ok(())
}
