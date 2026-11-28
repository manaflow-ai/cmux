//! The memory inspector page (`inspector/index.html`, built by
//! scripts/cmux-next/build-optchat-inspector-web.sh) is compiled into the
//! binary (inspect/http.rs). This copies it into OUT_DIR. When it is missing
//! (a checkout where nothing built the web bundles, a Testbox `cargo check`)
//! a small placeholder page takes its place and the `optchat_inspector_placeholder`
//! cfg is set, so the crate still builds and tests anywhere. An app or brain
//! build sets OPTCHAT_REQUIRE_INSPECTOR_PAGE=1 (build-optchat-chief.sh): then a
//! missing page fails the build loudly, so no release ships the placeholder.

use std::path::PathBuf;

const PLACEHOLDER: &str = "<!doctype html><meta charset=utf-8><title>Chief Memory Inspector</title>\
<body style=\"font:14px -apple-system,sans-serif;margin:24px\"><p>The inspector bundle was not built \
into this binary (scripts/cmux-next/build-optchat-inspector-web.sh).</p>";

fn main() {
    let page =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"))
            .join("inspector")
            .join("index.html");
    let out =
        PathBuf::from(std::env::var("OUT_DIR").expect("cargo sets OUT_DIR")).join("inspector.html");
    println!("cargo:rerun-if-changed={}", page.display());
    println!("cargo:rerun-if-env-changed=OPTCHAT_REQUIRE_INSPECTOR_PAGE");
    println!("cargo::rustc-check-cfg=cfg(optchat_inspector_placeholder)");
    match std::fs::read(&page) {
        Ok(bytes) => std::fs::write(&out, bytes).expect("write the inspector page into OUT_DIR"),
        Err(error) => {
            if std::env::var("OPTCHAT_REQUIRE_INSPECTOR_PAGE").as_deref() == Ok("1") {
                panic!(
                    "the memory inspector page {} is missing ({error}); run scripts/cmux-next/build-web-bundles.sh \
                     (or build-optchat-inspector-web.sh) before an app or brain build",
                    page.display()
                );
            }
            println!(
                "cargo:warning=optchat-chief: {} is missing; the inspector serves a placeholder page",
                page.display()
            );
            println!("cargo:rustc-cfg=optchat_inspector_placeholder");
            std::fs::write(&out, PLACEHOLDER).expect("write the placeholder page into OUT_DIR");
        }
    }
}
