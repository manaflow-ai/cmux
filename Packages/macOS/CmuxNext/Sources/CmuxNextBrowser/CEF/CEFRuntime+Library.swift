import CmuxNextWakeups
import Foundation

// The in-process load of the shim and the framework, and the wait for a preload's load.
extension CEFRuntime {
    /// Returns once the preload's load (behind the fence or not) ended.
    func libraryLoadEnded() async {
        _ = await preloadMap()?.value
    }

    /// The framework read as idle items behind the startup fence (``CEFFrameworkPrefetch/post(_:on:)``), awaited
    /// by one task of `work` that quit cancels.
    func postRead(_ layout: CEFRuntimeLayout, on work: BackgroundWork) -> Task<Bool, any Error> {
        prefetch.post(layout, on: work)
        return work.task(.bestEffort) { @Sendable [prefetch] () async -> Bool in await prefetch.finished() }
    }

    /// Maps the shim and the framework (`cef_load_library`, fork API lookup).
    /// Thread-safe: plain `dlopen`/`dlsym`, no Chromium code runs yet. The framework's files are read through
    /// `prefetch`, which skips those a fenced or promoted read already read.
    nonisolated static func loadLibrary(
        _ candidate: CEFRuntimeLayout?,
        signatureChecker: (any CEFCodeSignatureChecking)? = nil,
        prefetch: CEFFrameworkPrefetch
    ) -> Result<CEFLoadedLibrary, BootError> {
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
        var message = [CChar](repeating: 0, count: 512)
        let mapStarted = clock.now
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            let text = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.framework(text))
        }
        prefetch.noteMapped(clock.now - mapStarted)
        prefetch.warm(layout)
        // Lists the framework's locale directories here, off the main thread.
        let locale = CEFLocale.current(frameworkDirectory: layout.frameworkDirectory)
        return .success(CEFLoadedLibrary(shim: shim, shimABI: shimABI ?? "", layout: layout, locale: locale, loadDuration: clock.now - started))
    }
}
