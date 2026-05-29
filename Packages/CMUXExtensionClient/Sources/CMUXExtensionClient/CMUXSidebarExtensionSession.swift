import CmuxExtensionKit
import Foundation

/// Host-side session that mediates snapshot refreshes and action dispatch for one sidebar extension.
public actor CMUXSidebarExtensionSession {
    private let manifest: CMUXExtensionManifest
    private let client: CMUXSidebarHostClient
    private var latestSnapshot: CMUXSidebarSnapshot?

    /// Creates a sidebar extension session.
    /// - Parameters:
    ///   - manifest: Manifest for the extension attached to this session.
    ///   - client: Host callbacks used to fetch snapshots and dispatch actions.
    /// - Throws: Manifest validation errors.
    public init(manifest: CMUXExtensionManifest, client: CMUXSidebarHostClient) throws {
        try CMUXExtensionValidator.validateSidebarManifest(manifest)
        self.manifest = manifest
        self.client = client
    }

    /// Fetches and caches the latest sidebar snapshot.
    /// - Returns: Snapshot returned by the host client.
    /// - Throws: Errors thrown by the host snapshot callback.
    public func refreshSnapshot() async throws -> CMUXSidebarSnapshot {
        let snapshot = try await client.snapshot()
        latestSnapshot = snapshot
        return snapshot
    }

    /// Dispatches an extension action to the host.
    /// - Parameter action: Sidebar action requested by the extension UI.
    /// - Returns: Host action result.
    /// - Throws: Errors thrown by the host dispatch callback.
    public func perform(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult {
        try await client.dispatch(action)
    }

    /// Manifest associated with this session.
    public var extensionManifest: CMUXExtensionManifest {
        manifest
    }

    /// Last snapshot returned by `refreshSnapshot()`, if any.
    /// - Returns: Cached sidebar snapshot.
    public func cachedSnapshot() -> CMUXSidebarSnapshot? {
        latestSnapshot
    }
}
