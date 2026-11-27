//! How long to wait before a read that failed is tried again.

/// The first wait after a failure.
const FIRST_MS: u64 = 1_000;
/// No wait is longer than this.
const MAX_MS: u64 = 30_000;

/// The wait after `failures` reads in a row got no answer: 1 s, 2 s, 4 s and so on, at most
/// 30 s. No failure is no wait.
pub fn retry_after_ms(failures: u32) -> u64 {
    match failures {
        0 => 0,
        n => FIRST_MS.saturating_mul(1u64 << (n - 1).min(16)).min(MAX_MS),
    }
}

#[cfg(test)]
mod tests {
    use super::retry_after_ms;

    #[test]
    fn the_wait_doubles_up_to_thirty_seconds() {
        let waits: Vec<u64> = (0..8).map(retry_after_ms).collect();
        assert_eq!(waits, [0, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);
        assert_eq!(retry_after_ms(u32::MAX), 30_000);
    }
}
