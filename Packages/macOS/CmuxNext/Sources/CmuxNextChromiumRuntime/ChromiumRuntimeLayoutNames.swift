/// The names inside a pack's `Contents/Frameworks`, as
/// `scripts/cmux-next/embed-cef.sh` lays them out. CmuxNextBrowser's
/// `CEFRuntimeLayout` uses the same names to find the runtime; this leaf
/// module cannot import it, so the two are kept equal by
/// `ChromiumRuntimeInstallerTests` (a pack made with these names installs)
/// and `CEFRuntimeLayout.locate` (an installed pack is found).
struct ChromiumRuntimeLayoutNames {
    static let framework = "Chromium Embedded Framework.framework"
    static let shim = "libcmux_cef_shim.dylib"
}
