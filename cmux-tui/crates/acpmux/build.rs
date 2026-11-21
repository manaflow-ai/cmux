// The link arguments of acpmux's own binary. The build id is stamped in the
// leaf crate acpmux-build-id instead (its build.rs reruns on every new stamp and
// every commit, and a rerun recompiles every target of its package); this script
// reads no stamp and reruns only when it changes.
use std::path::{Path, PathBuf};

// The allowlist app_assets.rs serves, so the bundle holds exactly what /app/ can answer.
#[path = "src/server/app_asset_paths.rs"]
mod app_asset_paths;

/// The files under `dir` as `/`-joined relative names. Only regular files: a link is never followed.
fn files(dir: &Path, prefix: &str, out: &mut Vec<String>) {
    let entries =
        std::fs::read_dir(dir).unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()));
        let name = entry.file_name().to_string_lossy().into_owned();
        let relative = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => files(&entry.path(), &relative, out),
            Ok(kind) if kind.is_file() => out.push(relative),
            _ => {}
        }
    }
}

/// With ACPMUX_BUNDLED_APP_ASSETS_DIR set (the release build job points it at the output of
/// scripts/cmux-next/build-agent-pane-web.sh), writes `$OUT_DIR/app_bundle.rs`: the allowlisted
/// files, zstd-packed into the binary by cmux-embed. Unset, the bundle is empty.
fn bundle_app_assets() {
    const VAR: &str = "ACPMUX_BUNDLED_APP_ASSETS_DIR";
    println!("cargo:rerun-if-env-changed={VAR}");
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"));
    let mut entries = String::new();
    if let Some(dir) = std::env::var_os(VAR).filter(|v| !v.is_empty()).map(PathBuf::from) {
        println!("cargo:rerun-if-changed={}", dir.display());
        assert!(
            dir.join("index.html").is_file(),
            "{VAR}={} has no index.html: build it with scripts/cmux-next/build-agent-pane-web.sh --out",
            dir.display()
        );
        let staged = out.join("app-bundle");
        let _ = std::fs::remove_dir_all(&staged);
        std::fs::create_dir_all(&staged).expect("create app-bundle");
        let mut found = Vec::new();
        files(&dir, "", &mut found);
        found.sort();
        let mut index = 0;
        for relative in found {
            // Served empty without a file (app_assets.rs), so never embedded.
            if relative == "__snapshot/chat.js"
                || app_asset_paths::asset(&format!("/app/{relative}")).is_none()
            {
                continue;
            }
            std::fs::copy(dir.join(&relative), staged.join(index.to_string()))
                .unwrap_or_else(|e| panic!("cannot copy {relative}: {e}"));
            entries.push_str(&format!(
                "    ({relative:?}, cmux_embed::packed_str!(include_str!(concat!(env!(\"OUT_DIR\"), \"/app-bundle/{index}\")))),\n"
            ));
            index += 1;
        }
    }
    let source = format!(
        "/// The NEXT pane files embedded at build time: (path under /app/, text).\n\
         pub static BUNDLE: &[(&str, cmux_embed::PackedStr)] = &[\n{entries}];\n"
    );
    std::fs::write(out.join("app_bundle.rs"), source).expect("write app_bundle.rs");
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/server/app_asset_paths.rs");
    bundle_app_assets();
    // clap builds the complete acpmux command tree before dispatch. On Windows,
    // that now exceeds the linker's 1 MiB default main-thread stack and the
    // process aborts before parsing even `status`. Reserve 8 MiB (committed
    // pages still grow on demand) for both supported Windows linkers.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let flag = match std::env::var("CARGO_CFG_TARGET_ENV").as_deref() {
            Ok("msvc") => "/STACK:8388608",
            _ => "-Wl,--stack,8388608",
        };
        println!("cargo:rustc-link-arg-bin=acpmux={flag}");
    }
}
