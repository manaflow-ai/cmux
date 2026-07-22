public import Foundation

/// An immutable package copied into a profile's content-addressed store.
public struct BrowserWebExtensionInstalledPackage: Equatable, Sendable {
    /// Complete URL of the immutable managed package.
    public let url: URL

    /// SHA-256 digest of the package bytes and relative paths.
    public let digest: String

    /// Creates an immutable managed-package value.
    public init(url: URL, digest: String) {
        self.url = url
        self.digest = digest
    }
}
