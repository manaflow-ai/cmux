import CmuxExtensionKit
import Foundation

/// A sidebar extension registered with the host.
public struct CMUXSidebarExtensionRecord: Equatable, Identifiable, Sendable {
    /// Stable extension identifier from the manifest.
    public var id: String { manifest.id }
    /// Manifest describing the extension contract and requested scopes.
    public var manifest: CMUXExtensionManifest
    /// Whether the extension is provided by cmux rather than a third party.
    public var isHostProvided: Bool

    /// Creates a sidebar extension record.
    /// - Parameters:
    ///   - manifest: Manifest describing the extension.
    ///   - isHostProvided: Whether cmux provides the extension.
    public init(manifest: CMUXExtensionManifest, isHostProvided: Bool) {
        self.manifest = manifest
        self.isHostProvided = isHostProvided
    }
}
