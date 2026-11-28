import Foundation

/// The shim and framework, mapped by `CEFRuntime.loadLibrary`.
nonisolated struct CEFLoadedLibrary: Sendable {
    var shim: CEFShimLibrary
    /// The shim's ABI identity (`CEFShimABI`), checked when it loaded.
    var shimABI: String
    var layout: CEFRuntimeLayout
    /// UI locale and Accept-Language from the macOS preferred languages.
    var locale: CEFLocale
    var loadDuration: Duration
}
