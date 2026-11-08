// The link arguments of acpmux's own binary. The build id is stamped in the
// leaf crate acpmux-build-id instead (its build.rs reruns on every new stamp and
// every commit, and a rerun recompiles every target of its package); this script
// reads no stamp and reruns only when it changes.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
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
