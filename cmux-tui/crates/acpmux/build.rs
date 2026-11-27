// The link arguments of acpmux's own binary. The build id is stamped in the
// leaf crate acpmux-build-id instead (its build.rs reruns on every new stamp and
// every commit, and a rerun recompiles every target of its package); this script
// reads no stamp. A shipping build also embeds the production browser pane.
use std::fmt::Write as _;
use std::io::{Error, Result};
use std::path::{Path, PathBuf};

#[path = "src/server/app_asset_paths.rs"]
mod app_asset_paths;

/// What every production pane holds; a build missing one embeds nothing broken.
const REQUIRED: [&str; 8] = [
    "index.html",
    "pane.js",
    "pane.css",
    "pane-copy.css",
    "highlight-worker.js",
    "image-worker.js",
    "chat-snapshot.js",
    "locales/loader.js",
];

/// Writes `$OUT_DIR/browser_app_assets.rs`: `SHIPPED`, the files of
/// `ACPMUX_BUNDLED_APP_ASSETS_DIR` (the output of `build-agent-pane-web.sh`) sorted by
/// path, each zstd-packed by `cmux_embed`. Without the variable it is empty and the
/// daemon reads the pane from disk (`app_assets.rs`).
fn browser_assets() -> Result<()> {
    println!("cargo:rerun-if-env-changed=ACPMUX_BUNDLED_APP_ASSETS_DIR");
    println!("cargo:rerun-if-changed=src/server/app_asset_paths.rs");
    let mut files = match std::env::var_os("ACPMUX_BUNDLED_APP_ASSETS_DIR") {
        Some(directory) => pane_files(&std::fs::canonicalize(directory)?)?,
        None => Vec::new(),
    };
    files.sort();
    // An array by value: a `PackedStr` holds a `OnceLock`, which a static may own but not borrow.
    let mut generated =
        format!("static SHIPPED: [(&str, cmux_embed::PackedStr); {}] = [\n", files.len());
    for (name, file) in &files {
        println!("cargo:rerun-if-changed={}", file.display());
        let path = file
            .to_str()
            .ok_or_else(|| Error::other(format!("non-UTF-8 path {}", file.display())))?;
        let _ =
            writeln!(generated, "    ({name:?}, cmux_embed::packed_str!(include_str!({path:?}))),");
    }
    generated.push_str("];\n");
    let out = std::env::var_os("OUT_DIR").ok_or_else(|| Error::other("OUT_DIR is unset"))?;
    std::fs::write(PathBuf::from(out).join("browser_app_assets.rs"), generated)
}

/// Every file of the pane at `root`, as (path under `/app/`, file). Each must be one the
/// listener serves (`app_asset_paths::asset`), so a new builder output fails the build
/// instead of shipping unreachable.
fn pane_files(root: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut files = Vec::new();
    for subdir in ["", "chunks", "locales"] {
        let folder = root.join(subdir);
        println!("cargo:rerun-if-changed={}", folder.display());
        for entry in std::fs::read_dir(&folder)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name
                .to_str()
                .ok_or_else(|| Error::other(format!("non-UTF-8 name in {}", folder.display())))?;
            let kind = entry.file_type()?;
            if subdir.is_empty() && kind.is_dir() && matches!(name, "chunks" | "locales") {
                continue;
            }
            let relative =
                if subdir.is_empty() { name.to_owned() } else { format!("{subdir}/{name}") };
            if !kind.is_file() || app_asset_paths::asset(&format!("/app/{relative}")).is_none() {
                return Err(Error::other(format!("unsupported production pane asset: {relative}")));
            }
            files.push((relative, entry.path()));
        }
    }
    if let Some(missing) =
        REQUIRED.iter().find(|required| !files.iter().any(|(name, _)| name == *required))
    {
        return Err(Error::other(format!("missing production pane asset: {missing}")));
    }
    Ok(files)
}

/// Writes `$OUT_DIR/server_methods.rs` (`src/server/methods/mod.rs`): a module for each
/// `src/server/methods/<name>.rs` but `mod.rs` and `*_tests.rs`, sorted by name, and `dispatch`,
/// which runs the one whose `METHOD` is the request's method.
fn methods_dispatch() -> Result<()> {
    let folder = std::fs::canonicalize("src/server/methods")?;
    println!("cargo:rerun-if-changed={}", folder.display());
    let mut names = Vec::new();
    for entry in std::fs::read_dir(&folder)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return Err(Error::other(format!("non-UTF-8 name in {}", folder.display())));
        };
        // `mod.rs` holds `dispatch`; a `<name>_tests.rs` is its method file's test module.
        if let Some(stem) = name.strip_suffix(".rs")
            && stem != "mod"
            && !stem.ends_with("_tests")
        {
            println!("cargo:rerun-if-changed={}", path.display());
            names.push((stem.to_owned(), path));
        }
    }
    names.sort();
    let mut generated = String::new();
    for (name, path) in &names {
        let path = path
            .to_str()
            .ok_or_else(|| Error::other(format!("non-UTF-8 path {}", path.display())))?;
        let _ = writeln!(generated, "#[path = {path:?}]\npub(crate) mod {name};");
    }
    generated.push_str(concat!(
        "\n/// The reply of the method file whose `METHOD` is `m`; `None` when no file has it.\n",
        "pub(super) async fn dispatch(\n",
        "    hub: &Arc<Hub>,\n",
        "    conn: &Conn,\n",
        "    m: &str,\n",
        "    params: &Value,\n",
        ") -> Option<Result<Value, RpcError>> {\n",
        "    match m {\n",
    ));
    for (name, _) in &names {
        let _ = writeln!(
            generated,
            "        {name}::METHOD => Some(crate::heap_future::heap(|| {name}::handle(hub, conn, params)).await),"
        );
    }
    generated.push_str("        _ => None,\n    }\n}\n");
    let out = std::env::var_os("OUT_DIR").ok_or_else(|| Error::other("OUT_DIR is unset"))?;
    std::fs::write(PathBuf::from(out).join("server_methods.rs"), generated)
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if let Err(error) = browser_assets() {
        panic!("embedding the production browser pane: {error}");
    }
    if let Err(error) = methods_dispatch() {
        panic!("registering the request methods in src/server/methods: {error}");
    }
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
    // The shipped Linux build is a static PIE (musl), which relocates itself before main: every
    // short-lived acpmux (each hook, each CLI call) walks one 24-byte RELA entry per pointer in
    // its data, and a cold start first pages that table in. Packed relative relocations (DT_RELR)
    // store the same pointers as a bitmap of about one bit each. musl reads them since 1.2.4 (Rust
    // 1.95 ships 1.2.5); glibc only since 2.36, so the glibc builds keep RELA for older hosts.
    // Both linkers the Linux legs use take the flag (GNU ld 2.38+, lld 15+ through zig).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("musl")
    {
        println!("cargo:rustc-link-arg-bin=acpmux=-Wl,-z,pack-relative-relocs");
    }
}
