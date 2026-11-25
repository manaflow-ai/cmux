use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde_json::{Value, json};

use super::{branch_test_root, run_git, session_patch, stdio_rpc_json};

const TOKEN: &str = "0123456789abcdef";

struct Fixture {
    root: PathBuf,
    repo: PathBuf,
    generated: HashSet<String>,
    listing_bytes: usize,
}

impl Fixture {
    fn new(count: usize, long_paths: bool) -> Self {
        let (root, repo) = branch_test_root("generated-attrs", TOKEN, "generated-attrs");
        // A shared deep prefix crosses the old listing-byte bound without
        // requiring a large file or a path component over the filesystem limit.
        let prefix = if long_paths {
            (0..5)
                .map(|i| format!("{i}{}", "x".repeat(89)))
                .collect::<Vec<_>>()
                .join("/")
        } else {
            "generated".to_owned()
        };
        std::fs::create_dir_all(repo.join(&prefix)).expect("create generated directory");
        let mut paths: Vec<_> = (0..count)
            .map(|index| format!("{prefix}/bulk-{index:05}.generated"))
            .collect();
        paths.extend(
            [
                "plain.text",
                "cleared.unset",
                "only.diff-only",
                "only.true-only",
                "café\n雪.generated",
            ]
            .map(|name| format!("{prefix}/{name}")),
        );
        std::fs::write(
            repo.join(".gitattributes"),
            "*.generated linguist-generated=true -diff\n\
             *.text linguist-generated=false diff\n\
             *.unset !linguist-generated !diff\n\
             *.diff-only linguist-generated=false -diff\n\
             *.true-only linguist-generated=true diff\n",
        )
        .expect("write attributes");
        for path in &paths {
            std::fs::write(repo.join(path), b"before\n").expect("write tracked file");
        }
        run_git(&repo, &["add", "."]);
        run_git(&repo, &["commit", "--quiet", "-m", "attribute fixture"]);
        for path in &paths {
            std::fs::write(repo.join(path), b"after\n").expect("change tracked file");
        }
        let listing_bytes = paths.iter().map(|path| path.len() + 1).sum();
        let excluded = [
            format!("{prefix}/plain.text"),
            format!("{prefix}/cleared.unset"),
        ];
        let generated = paths
            .into_iter()
            .filter(|path| !excluded.contains(path))
            .collect();
        Self {
            root,
            repo,
            generated,
            listing_bytes,
        }
    }

    fn open(&self) -> Value {
        let response = stdio_rpc_json(
            &self.root,
            Path::new(env!("CARGO_BIN_EXE_diff-sidecar-test-host")),
            &[],
            &json!({
                "id": "generated-attributes",
                "version": 1,
                "method": "sessionOpen",
                "params": {
                    "source": {"kind": "unstaged", "repoRoot": self.repo},
                    "capabilityToken": TOKEN
                }
            }),
        );
        assert_eq!(response["result"]["type"], "sessionOpened", "{response}");
        response
    }

    fn assert_generated(&self, response: &Value) {
        let paths = response["result"]["value"]["generatedPaths"]
            .as_array()
            .expect("generated paths");
        let actual: HashSet<_> = paths
            .iter()
            .map(|path| path.as_str().expect("path").to_owned())
            .collect();
        assert_eq!(
            actual.len(),
            paths.len(),
            "both attributes must classify a path only once"
        );
        assert_eq!(
            actual.len(),
            self.generated.len(),
            "every generated file must be classified"
        );
        assert_eq!(actual, self.generated);
    }

    fn close(&self, response: &Value) {
        let closed = stdio_rpc_json(
            &self.root,
            Path::new(env!("CARGO_BIN_EXE_diff-sidecar-test-host")),
            &[],
            &json!({
                "id": "close-generated-attributes",
                "version": 1,
                "method": "sessionClose",
                "params": {"sessionId": response["result"]["value"]["sessionId"], "capabilityToken": TOKEN}
            }),
        );
        assert_eq!(closed["result"]["type"], "sessionClosed", "{closed}");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn rpc_generated_attributes_include_every_changed_path_past_count_and_byte_bounds() {
    let fixture = Fixture::new(10_000, true);
    assert!(fixture.listing_bytes > 4 * 1024 * 1024);
    let response = fixture.open();
    fixture.assert_generated(&response);
    let patch = session_patch(&fixture.root, TOKEN, &response, "cmux-diff-viewer://");
    let last_file = b"bulk-09999.generated";
    assert!(
        patch
            .windows(last_file.len())
            .any(|bytes| bytes == last_file)
    );
    fixture.close(&response);
}

/// Run the identical stdio session-open harness on base and head. Its payload
/// is supported on both, so the measured work and assertions stay the same.
#[test]
#[ignore = "explicit before/after performance harness"]
fn rpc_generated_attributes_performance() {
    let fixture = Fixture::new(4096, false);
    let mut samples = Vec::new();
    for index in 0..23 {
        let started = Instant::now();
        let response = fixture.open();
        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        fixture.assert_generated(&response);
        fixture.close(&response);
        if index >= 3 {
            samples.push(elapsed);
        }
    }
    samples.sort_by(f64::total_cmp);
    eprintln!(
        "GENERATED_ATTRIBUTES_PERF files=4101 samples=20 p50_ms={:.3} p95_ms={:.3} p99_ms={:.3}",
        samples[9], samples[18], samples[19],
    );
}
