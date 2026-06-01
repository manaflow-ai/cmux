@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation

/// Host-side session that mediates snapshot refreshes and action dispatch for one sidebar extension.
public actor CMUXSidebarExtensionSession {
    private let manifest: CMUXExtensionManifest
    private let client: CMUXSidebarHostClient
    private let grantedReadScopes: Set<CMUXExtensionScope>
    private let grantedActionScopes: Set<CMUXExtensionActionScope>
    private var latestSnapshot: CMUXSidebarSnapshot?

    /// Creates a sidebar extension session.
    /// - Parameters:
    ///   - manifest: Manifest for the extension attached to this session.
    ///   - client: Host callbacks used to fetch snapshots and dispatch actions.
    ///   - grantedReadScopes: Read scopes currently approved for this extension.
    ///   - grantedActionScopes: Action scopes currently approved for this extension.
    /// - Throws: Manifest validation errors.
    public init(
        manifest: CMUXExtensionManifest,
        client: CMUXSidebarHostClient,
        grantedReadScopes: Set<CMUXExtensionScope>? = nil,
        grantedActionScopes: Set<CMUXExtensionActionScope>? = nil
    ) throws {
        try validateSidebarManifest(manifest)
        self.manifest = manifest
        self.client = client
        self.grantedReadScopes = Set(manifest.requestedScopes).intersection(
            grantedReadScopes ?? Set(manifest.requestedScopes)
        )
        self.grantedActionScopes = Set(manifest.requestedActionScopes).intersection(
            grantedActionScopes ?? Set(manifest.requestedActionScopes)
        )
    }

    /// Fetches and caches the latest sidebar snapshot.
    /// - Returns: Host snapshot filtered to this session's granted read scopes.
    /// - Throws: Errors thrown by the host snapshot callback.
    public func refreshSnapshot() async throws -> CMUXSidebarSnapshot {
        let snapshot = try await client.snapshot().filtered(
            for: grantedReadScopes,
            actionScopes: grantedActionScopes
        )
        latestSnapshot = snapshot
        return snapshot
    }

    /// Dispatches an extension action to the host.
    /// - Parameter action: Sidebar action requested by the extension UI.
    /// - Returns: Host action result.
    /// - Throws: Errors thrown by the host dispatch callback.
    public func perform(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult {
        guard grantedActionScopes.isSuperset(of: action.requiredScopes) else {
            return .rejected("Extension action is not granted")
        }
        return try await client.dispatch(action)
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
