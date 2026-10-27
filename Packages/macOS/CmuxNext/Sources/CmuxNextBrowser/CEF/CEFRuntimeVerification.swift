import Foundation

/// The check of a downloaded runtime's code right before Chromium maps it: by ``CEFLibraryLoader``
/// before the in-process map, by ``CEFHostStart`` before it asks for the Chromium Host that maps it
/// (task p01-process-101). The download and this check stay in cmux in both backends; the host only
/// maps what cmux checked. A bundled runtime is covered by the app's signature and is not checked.
/// A blocking call (Security reads and hashes the code): never on the main thread.
nonisolated struct CEFRuntimeVerification: Sendable {
    /// Checks the code; nil: Security's code signature check.
    var checker: (any CEFCodeSignatureChecking)?

    init(checker: (any CEFCodeSignatureChecking)? = nil) {
        self.checker = checker
    }

    /// Why `layout` must not be mapped, or nil when it may be.
    func refusal(for layout: CEFRuntimeLayout) -> CEFRuntime.BootError? {
        guard case .downloaded(let teamID) = layout.trust else { return nil }
        guard let teamID else { return .untrusted("missing Developer ID team") }
        let checker = checker ?? SecCodeCEFCodeSignatureChecker()
        return checker.invalidItem(in: layout, teamID: teamID).map { .untrusted($0) }
    }
}
