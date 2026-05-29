import CmuxExtensionKit
import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI

/// Public identifiers for the CMUX sidebar ExtensionKit surface.
public enum CMUXSidebarExtensionPoint {
    /// Extension point identifier third-party sidebar extensions register against.
    public static let identifier = "com.manaflow.cmux.sidebar"
    /// Default ExtensionKit scene identifier hosted inside the cmux sidebar.
    public static let defaultSceneID = "sidebar"
}

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

/// Errors raised by the sidebar extension host client.
public enum CMUXExtensionClientError: Error, Equatable, Sendable {
    /// More than one extension used the same manifest identifier.
    case duplicateExtensionIdentifier(String)
    /// No registered extension matched the requested identifier.
    case extensionNotFound(String)
}

/// Validated collection of sidebar extensions available to the host.
public struct CMUXSidebarExtensionRegistry: Sendable {
    private var recordsByID: [String: CMUXSidebarExtensionRecord]

    /// Creates a registry from extension records.
    /// - Parameter records: Records to validate and store by identifier.
    /// - Throws: `CMUXExtensionClientError.duplicateExtensionIdentifier` for duplicate ids, or manifest validation errors.
    public init(records: [CMUXSidebarExtensionRecord] = []) throws {
        var recordsByID: [String: CMUXSidebarExtensionRecord] = [:]
        for record in records {
            try CMUXExtensionValidator.validateSidebarManifest(record.manifest)
            if recordsByID[record.id] != nil {
                throw CMUXExtensionClientError.duplicateExtensionIdentifier(record.id)
            }
            recordsByID[record.id] = record
        }
        self.recordsByID = recordsByID
    }

    /// Records sorted by display name for deterministic presentation.
    public var records: [CMUXSidebarExtensionRecord] {
        recordsByID.values.sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    /// Looks up one extension record.
    /// - Parameter id: Manifest identifier to find.
    /// - Returns: Matching record.
    /// - Throws: `CMUXExtensionClientError.extensionNotFound` when no record exists.
    public func record(id: String) throws -> CMUXSidebarExtensionRecord {
        guard let record = recordsByID[id] else {
            throw CMUXExtensionClientError.extensionNotFound(id)
        }
        return record
    }
}

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

/// Installed ExtensionKit sidebar extension discovered on the current Mac.
public struct CMUXInstalledSidebarExtension: Identifiable, Equatable, Sendable {
    /// Stable bundle identifier used for SwiftUI identity.
    public var id: String { bundleIdentifier }
    /// Extension bundle identifier.
    public var bundleIdentifier: String
    /// Localized extension display name.
    public var localizedName: String
    /// Extension point identifier declared by the extension.
    public var extensionPointIdentifier: String

    /// Creates an installed extension summary.
    /// - Parameters:
    ///   - bundleIdentifier: Extension bundle identifier.
    ///   - localizedName: Localized extension display name.
    ///   - extensionPointIdentifier: Extension point identifier declared by the extension.
    public init(
        bundleIdentifier: String,
        localizedName: String,
        extensionPointIdentifier: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.extensionPointIdentifier = extensionPointIdentifier
    }
}

@available(macOS 14.0, *)
/// Discovers installed sidebar extensions that match CMUX's ExtensionKit point.
public struct CMUXSidebarExtensionDiscovery {
    /// Creates an extension discovery helper.
    public init() {}

    /// Lists installed sidebar extensions.
    /// - Parameter extensionPointIdentifier: Extension point identifier to match.
    /// - Returns: Installed extensions sorted by localized name.
    /// - Throws: Errors thrown by ExtensionFoundation discovery.
    public func installedExtensions(
        extensionPointIdentifier: String = CMUXSidebarExtensionPoint.identifier
    ) async throws -> [CMUXInstalledSidebarExtension] {
        var identities = try AppExtensionIdentity.matching(appExtensionPointIDs: extensionPointIdentifier)
            .makeAsyncIterator()
        guard let update = await identities.next() else { return [] }
        return update.map {
            CMUXInstalledSidebarExtension(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName,
                extensionPointIdentifier: $0.extensionPointIdentifier
            )
        }
        .sorted { $0.localizedName < $1.localizedName }
    }
}

@available(macOS 14.0, *)
/// SwiftUI bridge that hosts a sidebar extension scene through ExtensionKit.
public struct CMUXSidebarExtensionHostView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = EXHostViewController

    /// Tracks the configuration currently installed on the host view controller.
    public final class Coordinator {
        fileprivate var currentKey: HostConfigurationKey?
    }

    fileprivate struct HostConfigurationKey: Equatable {
        var bundleIdentifier: String
        var sceneID: String
    }

    private let identity: AppExtensionIdentity
    private let sceneID: String

    /// Creates a sidebar extension host view.
    /// - Parameters:
    ///   - identity: Extension identity to host.
    ///   - sceneID: ExtensionKit scene identifier to render.
    public init(identity: AppExtensionIdentity, sceneID: String = CMUXSidebarExtensionPoint.defaultSceneID) {
        self.identity = identity
        self.sceneID = sceneID
    }

    /// Creates the configuration-tracking coordinator.
    /// - Returns: Coordinator for the hosted extension configuration.
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Creates the ExtensionKit host view controller.
    /// - Parameter context: SwiftUI representable context.
    /// - Returns: Configured `EXHostViewController`.
    public func makeNSViewController(context: Context) -> EXHostViewController {
        let viewController = EXHostViewController()
        context.coordinator.currentKey = configurationKey
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
        return viewController
    }

    /// Updates the host view controller when the hosted extension changes.
    /// - Parameters:
    ///   - viewController: Existing ExtensionKit host view controller.
    ///   - context: SwiftUI representable context.
    public func updateNSViewController(_ viewController: EXHostViewController, context: Context) {
        guard context.coordinator.currentKey != configurationKey else { return }
        context.coordinator.currentKey = configurationKey
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
    }

    private var configurationKey: HostConfigurationKey {
        HostConfigurationKey(bundleIdentifier: identity.bundleIdentifier, sceneID: sceneID)
    }
}
