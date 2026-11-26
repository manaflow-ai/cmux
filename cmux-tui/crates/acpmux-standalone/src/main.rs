//! The standalone acpmux binary the packages ship (staged as `acpmux`).
//!
//! The same program as the acpmux package's own `acpmux` binary, but the
//! acpmux lib is built without its `build-id` feature and this binary installs
//! the build id at start, as cmux-tui does. So the per-commit stamp
//! (acpmux-build-id) is a dependency of this binary only, and a commit that
//! leaves acpmux's sources alone does not recompile the acpmux lib: on a warm
//! Linux musl leg that recompile was 209 s of the acpmux group's 213 s (run
//! 43497362002).

// mimalloc on Linux (RFD 0156). The Linux packages are static musl builds, and musl's malloc
// never handed freed pages back: a daemon up 12 h on a lane VM held 2.5 GB in 9,818 anonymous
// regions, its live heap flat, and malloc_quiet_trim.rs trims glibc only. mimalloc purges freed
// pages itself, at once with `tune_allocator`.
#[cfg(target_os = "linux")]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

/// mimalloc's options for a long-lived daemon, as measured (RFD 0156): freed pages go back at
/// once (`purge_delay` 0, its default 10 ms kept 176 MB where musl kept 79 MB on the replay), and
/// arenas commit only what they touch. Ids from mimalloc.h's `mi_option_e`.
#[cfg(target_os = "linux")]
fn tune_allocator() {
    const MI_OPTION_ARENA_EAGER_COMMIT: std::ffi::c_int = 4;
    const MI_OPTION_PURGE_DELAY: std::ffi::c_int = 15;
    unsafe extern "C" {
        fn mi_option_set(option: std::ffi::c_int, value: std::ffi::c_long);
    }
    // SAFETY: plain integer options of the linked mimalloc (libmimalloc-sys); read at each purge.
    unsafe {
        mi_option_set(MI_OPTION_PURGE_DELAY, 0);
        mi_option_set(MI_OPTION_ARENA_EAGER_COMMIT, 0);
    }
}

fn main() -> anyhow::Result<()> {
    #[cfg(target_os = "linux")]
    tune_allocator();
    // Before anything reads `acpmux::hub::build()`. It only sets a OnceLock:
    // still one thread when `process_main` runs.
    acpmux::hub::install_build(acpmux_build_id::build());
    // SAFETY: no other thread runs yet (the line above starts none).
    unsafe { acpmux::cli::entry::process_main() }
}
