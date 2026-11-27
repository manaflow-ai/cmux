public import Foundation

/// Checks the code signature of one item of an unpacked pack.
///
/// ``SecCodeChromiumRuntimeSignatureChecker`` uses the Security framework;
/// tests pass a fake.
public protocol ChromiumRuntimeSignatureChecking: Sendable {
    /// Throws when `item` (a framework, dylib or app) is not validly signed by
    /// `teamID`'s Developer ID certificate.
    func check(_ item: URL, teamID: String) async throws(ChromiumRuntimeInstallError)
}
