use super::*;
use acpmux_book::gate_rounds;
use std::io::Write;
use std::time::Instant;

const FOLLOW_GATE_ROUNDS: usize = 5;
const FOLLOW_GATE_SAMPLES: usize = 3;

fn report_follow_gate(
    name: &str,
    small: &[Vec<u128>],
    god: &[Vec<u128>],
    unit: &str,
) -> io::Result<()> {
    gate_rounds::report(name, &[("small", small), ("god", god)]);
    let small_p95 = gate_rounds::best_p95(small);
    let god_p95 = gate_rounds::best_p95(god);
    let small_all = gate_rounds::all_p95(small);
    let god_all = gate_rounds::all_p95(god);
    assert!(god_p95 <= small_p95.saturating_mul(12) / 10, "{name}: best p95 ratio");
    assert!(god_all <= small_all.saturating_mul(2), "{name}: aggregate p95 ratio");
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small_p95},\"god_p95\":{god_p95},\"god_p95_all\":{god_all},\"unit\":\"{unit}\"}}"
    );
    println!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(file, "{line}")?;
    }
    Ok(())
}

struct FollowFixture {
    file: tempfile::NamedTempFile,
    source: FollowFileSource,
    cursor: u64,
    lines: usize,
}

fn fixture(rows: usize) -> io::Result<FollowFixture> {
    let mut file = tempfile::NamedTempFile::new()?;
    for row in 0..rows {
        writeln!(file, "history-{row}")?;
    }
    file.flush()?;
    let mut source = FollowFileSource::open(file.path())?;
    let mut cursor = 0;
    loop {
        let chunk = source.read_chunk(cursor)?;
        cursor = cursor.saturating_add(chunk.bytes().len() as u64);
        if chunk.at_end {
            break;
        }
    }
    Ok(FollowFixture { file, source, cursor, lines: rows })
}

fn side_mut(fixtures: &mut [FollowFixture; 2], side: usize) -> io::Result<&mut FollowFixture> {
    fixtures.get_mut(side).ok_or_else(|| invalid("follow fixture side"))
}

fn assert_fixture_shape(fixture: &FollowFixture) -> io::Result<()> {
    assert!(fixture.lines > 0);
    assert_eq!(fixture.file.as_file().metadata()?.len(), fixture.cursor);
    Ok(())
}

#[test]
#[ignore = "release gate: append after a caught-up transcript"]
fn v2_pr12_follow_append() -> io::Result<()> {
    let mut fixtures = [fixture(40)?, fixture(2_000_000)?];
    let mut rounds: [Vec<Vec<u128>>; 2] = [Vec::new(), Vec::new()];
    for round in 0..FOLLOW_GATE_ROUNDS {
        let order = if round % 2 == 0 { [0, 1] } else { [1, 0] };
        for side in order {
            let fixture = side_mut(&mut fixtures, side)?;
            let mut samples = Vec::with_capacity(FOLLOW_GATE_SAMPLES);
            for sample in 0..FOLLOW_GATE_SAMPLES {
                assert_fixture_shape(fixture)?;
                let line = format!("append-{round}-{sample}\n");
                writeln!(fixture.file, "append-{round}-{sample}")?;
                fixture.file.flush()?;
                let start = Instant::now();
                let chunk = fixture.source.read_chunk(fixture.cursor)?;
                let elapsed = start.elapsed().as_nanos();
                assert_eq!(chunk.bytes(), line.as_bytes());
                assert!(chunk.at_end);
                fixture.cursor = fixture.cursor.saturating_add(chunk.bytes().len() as u64);
                fixture.lines = fixture.lines.saturating_add(1);
                assert_fixture_shape(fixture)?;
                samples.push(elapsed);
            }
            rounds.get_mut(side).ok_or_else(|| invalid("follow rounds side"))?.push(samples);
        }
    }
    let small = rounds.first().ok_or_else(|| invalid("follow rounds small"))?;
    let god = rounds.get(1).ok_or_else(|| invalid("follow rounds god"))?;
    report_follow_gate("v2.pr12.follow_append", small, god, "ns")
}

#[test]
#[ignore = "release gate: chunked partial tail scans"]
fn v2_pr12_follow_scan_bytes() -> io::Result<()> {
    let mut fixtures = [fixture(40)?, fixture(2_000_000)?];
    let mut rounds: [Vec<Vec<u128>>; 2] = [Vec::new(), Vec::new()];
    for round in 0..FOLLOW_GATE_ROUNDS {
        let order = if round % 2 == 0 { [0, 1] } else { [1, 0] };
        for side in order {
            let fixture = side_mut(&mut fixtures, side)?;
            let mut samples = Vec::with_capacity(FOLLOW_GATE_SAMPLES);
            for _sample in 0..FOLLOW_GATE_SAMPLES {
                assert_fixture_shape(fixture)?;
                let before = fixture.source.stats();
                let appended = CHUNK_BYTES * 3 + 1;
                fixture.file.write_all(&vec![b'x'; CHUNK_BYTES * 3])?;
                fixture.file.flush()?;
                for chunk_no in 0..3 {
                    let chunk = fixture.source.read_chunk(fixture.cursor)?;
                    assert!(chunk.bytes().is_empty());
                    assert_eq!(chunk.at_end, chunk_no == 2);
                }
                fixture.file.write_all(b"\n")?;
                fixture.file.flush()?;
                let chunk = fixture.source.read_chunk(fixture.cursor)?;
                assert_eq!(chunk.lines().count(), 1);
                fixture.cursor = fixture.cursor.saturating_add(chunk.bytes().len() as u64);
                fixture.lines = fixture.lines.saturating_add(1);
                let after = fixture.source.stats();
                let bytes = after.bytes.saturating_sub(before.bytes);
                assert!(bytes <= (appended as u64).saturating_mul(2).saturating_add(8192));
                assert_fixture_shape(fixture)?;
                samples.push(bytes as u128);
            }
            rounds.get_mut(side).ok_or_else(|| invalid("follow rounds side"))?.push(samples);
        }
    }
    let small = rounds.first().ok_or_else(|| invalid("follow rounds small"))?;
    let god = rounds.get(1).ok_or_else(|| invalid("follow rounds god"))?;
    report_follow_gate("v2.pr12.follow_scan_bytes", small, god, "bytes")
}

#[test]
#[ignore = "release gate: bounded read_at slices"]
fn v2_pr12_follow_read_at() -> io::Result<()> {
    let mut fixtures = [fixture(40)?, fixture(2_000_000)?];
    let mut rounds: [Vec<Vec<u128>>; 2] = [Vec::new(), Vec::new()];
    for round in 0..FOLLOW_GATE_ROUNDS {
        let order = if round % 2 == 0 { [0, 1] } else { [1, 0] };
        for side in order {
            let fixture = side_mut(&mut fixtures, side)?;
            let mut samples = Vec::with_capacity(FOLLOW_GATE_SAMPLES);
            for _sample in 0..FOLLOW_GATE_SAMPLES {
                assert_fixture_shape(fixture)?;
                fixture.file.write_all(&vec![b'y'; 8192])?;
                fixture.file.write_all(b"\n")?;
                fixture.file.flush()?;
                let place = fixture.cursor;
                let start = Instant::now();
                let piece = fixture.source.read_at(place, 1024, 512)?;
                let elapsed = start.elapsed().as_nanos();
                assert_eq!(piece.bytes.len(), 512);
                assert!(!piece.ends);
                fixture.cursor = fixture.cursor.saturating_add(8193);
                fixture.lines = fixture.lines.saturating_add(1);
                assert_fixture_shape(fixture)?;
                samples.push(elapsed);
            }
            rounds.get_mut(side).ok_or_else(|| invalid("follow rounds side"))?.push(samples);
        }
    }
    let small = rounds.first().ok_or_else(|| invalid("follow rounds small"))?;
    let god = rounds.get(1).ok_or_else(|| invalid("follow rounds god"))?;
    report_follow_gate("v2.pr12.follow_read_at", small, god, "ns")
}
