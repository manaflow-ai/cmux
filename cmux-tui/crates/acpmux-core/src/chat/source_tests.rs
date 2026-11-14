use super::*;
use std::io::Write;

// The leading decimal is the test source's seq, with arbitrary gaps.
fn seq_places(line: &[u8], _: u64) -> io::Result<Range<u64>> {
    let seq = line.split(|byte| *byte == b' ').next().ok_or_else(|| invalid("missing seq"))?;
    let start: u64 =
        std::str::from_utf8(seq).map_err(io::Error::other)?.parse().map_err(io::Error::other)?;
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
fn tiny_lines_need_no_per_line_allocation() -> io::Result<()> {
    let chunk = Chunk::new(vec![b'\n'; CHUNK_BYTES], 0, byte_places, true, CHUNK_BYTES as u64);
    chunk.validate(0)?;
    assert_eq!(chunk.lines().count(), CHUNK_BYTES);
    assert_eq!(chunk.resident_bytes(), CHUNK_BYTES);
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
    assert_eq!(small, god);
    eprintln!(
        "v2.pr03a.source_read_bounds read_ratio={} holds_ratio={}",
        god.0 as f64 / small.0 as f64,
        god.1 as f64 / small.1 as f64
    );
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(
            output,
            "{{\"name\":\"v2.pr03a.source_read_bounds\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"bytes\"}}",
            small.0, god.0
        )?;
    }
    Ok(())
}
