//! reqwest keeps one DNS resolver per client, so `.dns_resolver(..)` on a builder from
//! `egress::http_client_builder` replaces the egress gate's and the client goes ungated (no host
//! check, no seeded-secret capture: the `seeded_secret` red after #54957). Only `src/egress` may
//! set a resolver; everyone else passes theirs to `egress::http_client_builder_with`.

use std::path::{Path, PathBuf};

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn only_the_egress_module_sets_a_resolver() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    for name in ["cmux-mobile-link", "cmux-mobile-host"] {
        let src = crates.join(name).join("src");
        if src.is_dir() {
            rust_files(&src, &mut files);
        }
    }
    let egress = crates.join("cmux-mobile-link/src/egress");
    let found: Vec<String> = files
        .iter()
        .filter(|f| !f.starts_with(&egress))
        .flat_map(|f| {
            std::fs::read_to_string(f)
                .unwrap()
                .lines()
                .enumerate()
                .filter(|(_, l)| l.contains(".dns_resolver(") && !l.trim_start().starts_with("//"))
                .map(|(n, _)| format!("{}:{}", f.display(), n + 1))
                .collect::<Vec<_>>()
        })
        .collect();
    assert!(found.is_empty(), "set the resolver through egress::http_client_builder_with: {found:?}");
}
