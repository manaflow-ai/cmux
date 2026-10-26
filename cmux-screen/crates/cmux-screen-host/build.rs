fn main() {
    // libwebrtc's macOS code is Objective-C categories in a static library:
    // without -ObjC the linker drops them and the factory aborts at startup
    // (LiveKit's documented requirement for macOS).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg=-ObjC");
        // screencapturekit's Swift bridge loads the OS's Swift runtime.
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}
