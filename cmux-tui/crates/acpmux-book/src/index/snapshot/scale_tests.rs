use super::*;
use crate::index::{IndexRecord, ReadSide};

#[test]
fn physical_page_reads_one_block_and_logarithmic_directory_steps() {
    const PAGE_ROWS: usize = 20;
    const STRIDE_ROWS: usize = 256;
    let row = |n: u64| {
        let mut row = Summary::new(format!("row-{n:06}"));
        row.last_activity = 2_000_000 - n;
        row.state = "closed".to_owned();
        row
    };
    let sample = row(0);
    let record_bytes = codec::encode(&IndexRecord {
        seq: 1,
        origin: sample.origin.clone(),
        chat_id: sample.chat_id.clone(),
        summary: sample,
        gone: false,
    })
    .unwrap()
    .len()
        + TRAILER_BYTES;
    assert!(STRIDE_ROWS * record_bytes < SEEK_BYTES);
    let data_bytes = (STRIDE_ROWS + PAGE_ROWS) * record_bytes;
    let mut observed = Vec::new();
    for count in [512_u64, 131_072] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.snap");
        SortedSnapshot::write_stream(&path, 1, 0, None, (0..count).map(|n| Ok(Arc::new(row(n)))))
            .unwrap();
        let disk = DiskSnapshot::open(path).unwrap().unwrap();
        // Both anchors are ten rows into a full 256-row block; the large
        // fixture's block is in the middle of its file. Fixed-width fields
        // keep every record the same length, independent of list size.
        let anchor_ordinal = if count == 512 { 10 } else { count / 2 + 10 };
        let key = SortKey::of(&row(anchor_ordinal));
        let page =
            disk.read_piece(Some(&key), ReadSide::After, false, PAGE_ROWS, PAGE_BYTES).unwrap();
        assert_eq!(page.rows.len(), PAGE_ROWS);
        assert_eq!(page.first_ordinal, anchor_ordinal + 1);
        assert!(page.has_before && page.has_after);
        for (offset, actual) in page.rows.iter().enumerate() {
            assert_eq!(actual.key(), row(anchor_ordinal + 1 + offset as u64).key());
        }
        let blocks = count as usize / STRIDE_ROWS + 1; // includes terminal entry
        assert_eq!(disk.head.directory_bytes, blocks * CHECKPOINT_BYTES);
        // One block + one page, then at most floor(log2(blocks)) + 1
        // binary-search probes and three entries for the terminal, next,
        // and fallback checkpoints. Reading the entire directory at 131k
        // would exceed this logarithmic allowance by more than 250 KiB.
        let seek_steps = blocks.ilog2() as usize + 1;
        let directory_budget = CHECKPOINT_BYTES * (3 + seek_steps);
        assert!(page.bytes_read >= data_bytes);
        assert!(page.bytes_read <= data_bytes + directory_budget);
        observed.push((page.bytes_read, directory_budget));
    }
    let (small_bytes, _) = observed[0];
    let (large_bytes, large_seek_budget) = observed[1];
    assert!(large_bytes >= small_bytes);
    assert!(large_bytes - small_bytes <= large_seek_budget);
}
