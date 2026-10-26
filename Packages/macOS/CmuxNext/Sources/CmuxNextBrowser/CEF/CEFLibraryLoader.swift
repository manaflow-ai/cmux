import Foundation

/// Maps the in-process shim and the framework (`cef_load_library`, fork API lookup), reading the framework's
/// files into the file cache through ``prefetch`` first. Thread-safe: plain `dlopen`/`dlsym`, no Chromium code
/// runs yet. The runtime's loader reads through the runtime's prefetch (``CEFRuntime/prefetch``), so what a
/// fenced or promoted read already read is not read again.
nonisolated struct CEFLibraryLoader: Sendable {
    /// The framework read the load goes through.
    let prefetch: CEFFrameworkPrefetch
    /// Checks a downloaded runtime's code before it loads; nil: Security's code signature check.
    var signatureChecker: (any CEFCodeSignatureChecking)?

    init(prefetch: CEFFrameworkPrefetch, signatureChecker: (any CEFCodeSignatureChecking)? = nil) {
        self.prefetch = prefetch
        self.signatureChecker = signatureChecker
    }

    /// Maps the shim and the framework of `candidate`.
    func load(_ candidate: CEFRuntimeLayout?) -> Result<CEFLoadedLibrary, CEFRuntime.BootError> {
        guard let layout = candidate else { return .failure(.notEmbedded) }
        if case .downloaded(let teamID) = layout.trust {
            guard let teamID else { return .failure(.untrusted("missing Developer ID team")) }
            let checker = signatureChecker ?? SecCodeCEFCodeSignatureChecker()
            if let invalid = checker.invalidItem(in: layout, teamID: teamID) {
                return .failure(.untrusted(invalid))
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let shim: CEFShimLibrary
        let shimABI = CEFShimABI.bundledIdentity()
        do { shim = try CEFShimLibrary.open(layout.shim, expected: shimABI) } catch { return .failure(.shim(error)) }
        // Read the binary before mapping it: `dlopen` holds dyld's loader
        // lock for the whole map, and every main-thread dlopen/dladdr waits
        // on that lock (CEFFrameworkPrefetch).
        prefetch.readBinary(layout)
        let mapStarted = clock.now
        if let message = shim.loadFramework(layout.frameworkBinary.path) {
            return .failure(.framework(message))
        }
        prefetch.noteMapped(clock.now - mapStarted)
        prefetch.warm(layout)
        // Lists the framework's locale directories here, off the main thread.
        let locale = CEFLocale.current(frameworkDirectory: layout.frameworkDirectory)
        return .success(CEFLoadedLibrary(shim: shim, shimABI: shimABI ?? "", layout: layout, locale: locale, loadDuration: clock.now - started))
    }
}
