// The Windows main-thread stack reservation of acpmux's own binary
// (crates/acpmux/build.rs): clap builds the complete acpmux command tree before
// dispatch, which exceeds the linker's 1 MiB default. Reads no stamp.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let flag = match std::env::var("CARGO_CFG_TARGET_ENV").as_deref() {
            Ok("msvc") => "/STACK:8388608",
            _ => "-Wl,--stack,8388608",
        };
        println!("cargo:rustc-link-arg-bins={flag}");
    }
}
