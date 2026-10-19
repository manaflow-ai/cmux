//! Links libtailscale: Tailscale's Go tsnet built as a C archive (BSD-3-Clause).
//!
//! Sources, in order:
//! - `LIBTAILSCALE_A`: a prebuilt `libtailscale.a` (CI caches one per target;
//!   it must be built from the pinned commit with `patches/` applied).
//! - `LIBTAILSCALE_SRC`: a libtailscale checkout, copied into `OUT_DIR`,
//!   patched, and built with `go build -buildmode=c-archive`.
//! - otherwise the pinned upstream commit is fetched into `OUT_DIR`, patched and built.
//!
//! The pin is the only place the Tailscale version is chosen; bump it on
//! purpose, never float it. `patches/*.patch` are applied in name order.

use std::path::{Path, PathBuf};
use std::process::Command;

const REPO: &str = "https://github.com/tailscale/libtailscale";
const PINNED: &str = "d1dc45d039edb7759ecbee6ba2aea0c4bca884b8";

fn main() {
    println!("cargo:rerun-if-env-changed=LIBTAILSCALE_A");
    println!("cargo:rerun-if-env-changed=LIBTAILSCALE_SRC");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let key = patch_key();
    let archive = match std::env::var_os("LIBTAILSCALE_A") {
        Some(path) => PathBuf::from(path),
        None => {
            let source = match std::env::var_os("LIBTAILSCALE_SRC") {
                Some(path) => copy_source(&PathBuf::from(path), &out),
                None => fetch_pinned(&out, &key),
            };
            patch(&source, &key);
            build(&source, &out)
        }
    };
    let folder = archive.parent().expect("archive folder");
    println!("cargo:rustc-link-search=native={}", folder.display());
    println!("cargo:rustc-link-lib=static=tailscale");
    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") | Ok("ios") => {
            for framework in ["CoreFoundation", "Security", "SystemConfiguration", "IOKit"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
            println!("cargo:rustc-link-lib=resolv");
        }
        Ok("linux") => {
            println!("cargo:rustc-link-lib=pthread");
            println!("cargo:rustc-link-lib=resolv");
        }
        _ => {}
    }
}

fn fetch_pinned(out: &Path, key: &str) -> PathBuf {
    let source = out.join(format!("libtailscale-{}", &PINNED[..12]));
    if std::fs::read_to_string(source.join(".cmux-patched")).is_ok_and(|done| done == key) {
        return source;
    }
    let _ = std::fs::remove_dir_all(&source);
    run(Command::new("git").args(["init", "-q"]).arg(&source));
    run(Command::new("git").arg("-C").arg(&source).args(["fetch", "-q", "--depth", "1", REPO, PINNED]));
    run(Command::new("git").arg("-C").arg(&source).args(["checkout", "-q", "FETCH_HEAD"]));
    source
}

fn copy_source(from: &Path, out: &Path) -> PathBuf {
    println!("cargo:rerun-if-changed={}", from.display());
    let source = out.join("libtailscale-src");
    let _ = std::fs::remove_dir_all(&source);
    run(Command::new("cp").arg("-R").arg(from).arg(&source));
    source
}

fn patches() -> Vec<PathBuf> {
    let folder = Path::new(env!("CARGO_MANIFEST_DIR")).join("patches");
    println!("cargo:rerun-if-changed={}", folder.display());
    let mut patches: Vec<PathBuf> = std::fs::read_dir(&folder)
        .map(|entries| entries.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect())
        .unwrap_or_default();
    patches.retain(|path| path.extension().is_some_and(|ext| ext == "patch"));
    patches.sort();
    patches
}

/// The pin plus the patch set: a cached source with another key is fetched again.
fn patch_key() -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for patch in patches() {
        std::fs::read(&patch).expect("patch file").hash(&mut hasher);
    }
    format!("{PINNED} {:016x}", hasher.finish())
}

/// Applies `patches/` once per key (a marker file records it).
fn patch(source: &Path, key: &str) {
    let marker = source.join(".cmux-patched");
    if std::fs::read_to_string(&marker).is_ok_and(|done| done == key) {
        return;
    }
    for patch in patches() {
        run(Command::new("git").arg("-C").arg(source).args(["apply", "--whitespace=nowarn"]).arg(&patch));
    }
    std::fs::write(marker, key).expect("patch marker");
}

fn build(source: &Path, out: &Path) -> PathBuf {
    let archive = out.join("libtailscale.a");
    let mut go = Command::new(std::env::var("GO").unwrap_or_else(|_| "go".into()));
    go.current_dir(source)
        .env("CGO_ENABLED", "1")
        .args(["build", "-trimpath", "-buildmode=c-archive", "-o"])
        .arg(&archive);
    if let Some(goarch) = goarch() {
        go.env("GOARCH", goarch);
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // Match the app's deployment target so the linker does not warn per object.
        let target = std::env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "14.0".into());
        go.env("MACOSX_DEPLOYMENT_TARGET", &target)
            .env("CGO_CFLAGS", format!("-mmacosx-version-min={target}"))
            .env("CGO_LDFLAGS", format!("-mmacosx-version-min={target}"));
    }
    run(&mut go);
    archive
}

fn goarch() -> Option<&'static str> {
    match std::env::var("CARGO_CFG_TARGET_ARCH").ok()?.as_str() {
        "aarch64" => Some("arm64"),
        "x86_64" => Some("amd64"),
        _ => None,
    }
}

fn run(command: &mut Command) {
    let status = command.status().unwrap_or_else(|error| panic!("{command:?}: {error}"));
    assert!(status.success(), "{command:?} failed: {status}");
}
