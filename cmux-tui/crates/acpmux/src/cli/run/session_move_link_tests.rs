use super::*;

#[test]
fn the_incident_estimates_hours_over_the_relay_and_minutes_over_a_direct_link() {
    // The 2026-11-22 coordinator chat: 6.8 GB of event log.
    let wire = wire_bytes(6_800_000_000);
    assert!(copy_secs(wire, 96_000.0) > SLOW_COPY.as_secs_f64());
    assert!(copy_secs(wire, 1_000_000.0) < SLOW_COPY.as_secs_f64() / 4.0);
    assert_eq!(rate_text(96_000.0), "96 KB/s");
    assert_eq!(rate_text(1_000_000.0), "1.0 MB/s");
}

#[test]
fn noise_does_not_compress() {
    let bytes = noise(1 << 16);
    let packed = zstd::bulk::compress(&bytes, 3).unwrap();
    assert!(packed.len() > bytes.len() * 9 / 10);
}
