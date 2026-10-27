import Foundation

/// The shim and framework, mapped into this process by `CEFLibraryLoader`: the in-process backend only.
/// Host mode never builds one (``CEFAttachedHost`` is its counterpart): the Chromium Host maps the framework.
nonisolated struct CEFLoadedLibrary: Sendable {
    var shim: CEFShimLibrary
    /// The shim's ABI identity (`CEFShimABI`), checked when it loaded.
    var shimABI: String
    var layout: CEFRuntimeLayout
    /// UI locale and Accept-Language from the macOS preferred languages.
    var locale: CEFLocale
    var loadDuration: Duration
}
