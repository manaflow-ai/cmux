public import Foundation

/// Checks the code signature of one item of an unpacked pack.
///
/// ``SecCodeChromiumRuntimeSignatureChecker`` uses the Security framework;
/// tests pass a fake.
public protocol ChromiumRuntimeSignatureChecking: Sendable {
    /// Throws when `item` (a framework, dylib or app) is not validly signed by
    /// `teamID`'s Developer ID certificate, or ``ChromiumRuntimeInstallError/cancelled``
    /// when the check stopped before it ran (nothing vouched for the item).
    /// `priority` is the install job's: a background prefetch checks at best effort,
    /// a person's request at user-visible priority.
    func check(_ item: URL, teamID: String, priority: ChromiumRuntimeInstaller.Priority) async throws(ChromiumRuntimeInstallError)
}
