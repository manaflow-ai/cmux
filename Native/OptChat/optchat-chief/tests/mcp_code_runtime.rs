//! Code mode runs Node with `--input-type=module-typescript`, which Node has from 22.18 only.
//! An older Node first on PATH was still picked, so every script failed with "--input-type must
//! be \"module\" or \"commonjs\"" (CI, 2026-11-19: the runner's /usr/bin/node; run 44410193269).
//! The search now passes over such a Node to a newer one, and a Node the person names in
//! `CMUX_MCP_CODE_RUNTIME` that is too old is refused with its version, before any script runs.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use optchat_chief::mcp_hub::codemode::find_runtime;
use optchat_chief::mcp_hub::{Caller, McpHub};
use serde_json::json;

/// A stand-in `node` in `dir` that answers `--version` with `version`.
fn node(dir: &Path, version: &str) -> PathBuf {
    std::fs::create_dir_all(dir).unwrap();
    let path = dir.join("node");
    std::fs::write(&path, format!("#!/bin/sh\necho {version}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn search(path: &str, home: &Path) -> Option<PathBuf> {
    let home = home.to_string_lossy().into_owned();
    let path = path.to_owned();
    find_runtime(&move |k: &str| match k {
        "PATH" => Some(path.clone()),
        "HOME" => Some(home.clone()),
        "CMUX_MCP_CODE_RUNTIME" => Some("node".into()),
        _ => None,
    })
    .map(|r| r.program)
}

#[test]
fn a_node_too_old_for_typescript_is_passed_over() {
    let tmp = tempfile::tempdir().unwrap();
    let (old, new) = (tmp.path().join("old"), tmp.path().join("new"));
    node(&old, "v20.11.1");
    let newer = node(&new, "v22.18.0");
    let path = format!("{}:{}", old.display(), new.display());
    assert_eq!(search(&path, tmp.path()), Some(newer));
}

#[test]
fn a_new_enough_node_first_on_path_is_used() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b) = (tmp.path().join("a"), tmp.path().join("b"));
    let first = node(&a, "v24.1.0");
    node(&b, "v22.18.0");
    let path = format!("{}:{}", a.display(), b.display());
    assert_eq!(search(&path, tmp.path()), Some(first));
}

/// The person names an old Node by its path: `mcp run` says which Node and why, not a failure
/// from inside the script.
#[test]
fn a_named_node_too_old_for_typescript_is_refused_with_its_version() {
    let tmp = tempfile::tempdir().unwrap();
    let old = node(&tmp.path().join("old"), "v20.11.1");
    let home = tmp.path().to_string_lossy().into_owned();
    let named = old.to_string_lossy().into_owned();
    let hub = McpHub::with_env(
        tmp.path().join("hub"),
        tmp.path().join("shared"),
        None,
        Arc::new(|_: String| {}),
        Arc::new(move |k: &str| match k {
            "HOME" => Some(home.clone()),
            "PATH" => Some(String::new()),
            "CMUX_MCP_CODE_RUNTIME" => Some(named.clone()),
            _ => None,
        }),
    );
    let err = hub
        .handle(
            &json!({"action": "run", "code": "return 1;"}),
            &Caller::Chief,
        )
        .expect_err("an old Node is refused");
    for want in ["CMUX_MCP_CODE_RUNTIME", "v20.11.1", "22.18"] {
        assert!(err.contains(want), "{want:?} missing: {err}");
    }
}
