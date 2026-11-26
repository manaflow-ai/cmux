use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkReport {
    pub sample_bytes: usize,
    pub iterations: usize,
    pub manifest_decode_median_micros: u128,
    pub manifest_decode_p95_micros: u128,
    pub sequential_read_median_micros: u128,
    pub sequential_read_p95_micros: u128,
    pub sequential_read_mib_per_second: f64,
}

struct TemporaryBenchmarkDirectory(PathBuf);

impl Drop for TemporaryBenchmarkDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Measures manifest decoding and sequential patch reads.
///
/// # Errors
///
/// Returns an error when the fixture cannot be created, decoded, or read.
pub fn run(sample_bytes: usize, iterations: usize) -> Result<BenchmarkReport, String> {
    if iterations == 0 {
        return Err("benchmark requires at least one iteration".to_owned());
    }
    let root = std::env::temp_dir().join(format!("cmux-diff-benchmark-{}", std::process::id()));
    std::fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    let _temporary_directory = TemporaryBenchmarkDirectory(root.clone());
    let patch_path = root.join("sample.patch");
    let chunk = b"diff --git a/src/file.rs b/src/file.rs\n@@ -1 +1 @@\n-old\n+new\n";
    let mut patch = Vec::with_capacity(sample_bytes);
    while patch.len() < sample_bytes {
        patch.extend_from_slice(chunk);
    }
    patch.truncate(sample_bytes);
    std::fs::write(&patch_path, &patch).map_err(|error| error.to_string())?;

    let manifest = serde_json::json!({
        "token": "0123456789abcdef",
        "files": [{
            "request_path": "/sample.patch",
            "file_path": patch_path,
            "mime_type": "text/x-diff",
            "remote_url": null
        }]
    });
    let manifest_bytes = serde_json::to_vec(&manifest).map_err(|error| error.to_string())?;
    let mut decode_samples = Vec::with_capacity(iterations);
    let mut read_samples = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let started = Instant::now();
        let _: crate::manifest::Manifest =
            serde_json::from_slice(&manifest_bytes).map_err(|error| error.to_string())?;
        decode_samples.push(started.elapsed());

        let started = Instant::now();
        let bytes = std::fs::read(&patch_path).map_err(|error| error.to_string())?;
        if bytes.len() != sample_bytes {
            return Err("benchmark read returned wrong byte count".to_owned());
        }
        read_samples.push(started.elapsed());
    }
    let decode_median = percentile(&mut decode_samples, 50);
    let decode_p95 = percentile(&mut decode_samples, 95);
    let read_median = percentile(&mut read_samples, 50);
    let read_p95 = percentile(&mut read_samples, 95);
    let seconds = read_median.as_secs_f64().max(f64::EPSILON);
    let sample_bytes_f64 = f64::from(
        u32::try_from(sample_bytes).map_err(|_| "benchmark sample exceeds 4 GiB".to_owned())?,
    );
    let mib_per_second = (sample_bytes_f64 / (1024.0 * 1024.0)) / seconds;
    Ok(BenchmarkReport {
        sample_bytes,
        iterations,
        manifest_decode_median_micros: decode_median.as_micros(),
        manifest_decode_p95_micros: decode_p95.as_micros(),
        sequential_read_median_micros: read_median.as_micros(),
        sequential_read_p95_micros: read_p95.as_micros(),
        sequential_read_mib_per_second: mib_per_second,
    })
}

fn percentile(samples: &mut [Duration], percentile: usize) -> Duration {
    samples.sort_unstable();
    let rank = samples.len().saturating_mul(percentile).div_ceil(100);
    let index = rank.saturating_sub(1).min(samples.len() - 1);
    samples[index]
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    #[test]
    fn zero_iterations_return_an_error() {
        assert!(super::run(1024, 0).is_err());
    }

    #[test]
    fn small_sample_runs_successfully() {
        assert!(super::run(1024, 1).is_ok());
    }

    #[test]
    fn percentile_uses_nearest_rank_for_small_samples() {
        let mut samples = [1, 2, 3, 4, 5].map(Duration::from_millis);
        assert_eq!(
            super::percentile(&mut samples, 95),
            Duration::from_millis(5)
        );
    }
}
