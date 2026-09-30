import Foundation

/// The shim and framework, mapped by `CEFRuntime.loadLibrary`.
nonisolated struct CEFLoadedLibrary: Sendable {
    var shim: CEFShimLibrary
    var layout: CEFRuntimeLayout
    var loadDuration: Duration
}
