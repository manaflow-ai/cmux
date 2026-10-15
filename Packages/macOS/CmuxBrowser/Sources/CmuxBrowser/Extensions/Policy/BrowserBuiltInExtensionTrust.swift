import CryptoKit
public import Foundation

/// Resolves the running app's own built-in uBlock Origin folder, trusted
/// only when its manifest matches the pinned hash.
///
/// Construct once at app start with `Bundle.main.resourceURL` and inject.
public struct BrowserBuiltInExtensionTrust: Equatable, Sendable {
    /// The trusted folder (symlinks resolved), or nil when absent or the manifest does not match the pin.
    public let trustedAdBlockerFolder: String?

    /// Reads and checks the bundled manifest.
    ///
    /// - Parameters:
    ///   - resources: The app's resources folder.
    ///   - expectedSHA256: The pinned manifest hash.
    ///   - readFile: File reader (injected for tests).
    public init(
        resources: URL?,
        expectedSHA256: String = BrowserBuiltInExtensions.adBlockerManifestSHA256,
        readFile: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        guard let resources else {
            trustedAdBlockerFolder = nil
            return
        }
        let folder = resources.appendingPathComponent(BrowserBuiltInExtensions.adBlockerFolder)
            .resolvingSymlinksInPath().standardizedFileURL
        guard let manifest = readFile(folder.appendingPathComponent("manifest.json")) else {
            trustedAdBlockerFolder = nil
            return
        }
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        trustedAdBlockerFolder = digest == expectedSHA256 ? folder.path : nil
    }
}
