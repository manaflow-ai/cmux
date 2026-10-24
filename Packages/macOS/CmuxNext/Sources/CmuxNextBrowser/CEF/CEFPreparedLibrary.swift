import Foundation

/// The off-main part of the Chromium load (`CEFRuntime.prepareLibrary`): the
/// shim is open and the framework binary read, but the framework is not
/// mapped yet. `CEFRuntime.mapFramework` maps it on the main thread.
nonisolated struct CEFPreparedLibrary: Sendable {
    var shim: CEFShimLibrary
    /// The shim's ABI identity (`CEFShimABI`), checked when it loaded.
    var shimABI: String
    var layout: CEFRuntimeLayout
    /// UI locale and Accept-Language, looked up off the main thread; nil
    /// makes the map look it up.
    var locale: CEFLocale?
    /// When the load began, for `CEFLoadedLibrary.loadDuration`.
    var started: ContinuousClock.Instant
}
