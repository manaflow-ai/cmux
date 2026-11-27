//! The standalone acpmux binary the packages ship (staged as `acpmux`).
//!
//! The same program as the acpmux package's own `acpmux` binary, but the
//! acpmux lib is built without its `build-id` feature and this binary installs
//! the build id at start, as cmux-tui does. So the per-commit stamp
//! (acpmux-build-id) is a dependency of this binary only, and a commit that
//! leaves acpmux's sources alone does not recompile the acpmux lib: on a warm
//! Linux musl leg that recompile was 209 s of the acpmux group's 213 s (run
//! 43497362002).

fn main() -> anyhow::Result<()> {
    // Before anything reads `acpmux::hub::build()`. It only sets a OnceLock:
    // still one thread when `process_main` runs.
    acpmux::hub::install_build(acpmux_build_id::build());
    // SAFETY: no other thread runs yet (the line above starts none).
    unsafe { acpmux::cli::entry::process_main() }
}
