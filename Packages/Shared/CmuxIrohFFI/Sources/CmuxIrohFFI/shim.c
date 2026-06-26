// CmuxIrohFFI is a header-providing shim over the Rust staticlib built from
// Native/cmux-iroh (the gitignored CmuxIrohFFI.xcframework carries no
// headers, deliberately: Xcode copies every linked static xcframework's
// Headers/ into one shared BUILT_PRODUCTS_DIR/include/, so a second
// module.modulemap there would collide with GhosttyKit's). SwiftPM generates
// the CmuxIrohFFI module from include/cmux_iroh_ffi.h; the symbols come from
// the binary target at link time. This file only satisfies SwiftPM's
// requirement that a C target has at least one source file.
typedef int cmux_iroh_ffi_shim_translation_unit_is_intentionally_empty;
