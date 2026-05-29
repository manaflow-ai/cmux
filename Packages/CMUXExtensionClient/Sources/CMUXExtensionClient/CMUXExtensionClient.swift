import CmuxExtensionKit
import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI

public enum CMUXSidebarExtensionPoint {
    public static let identifier = "com.manaflow.cmux.sidebar"
    public static let defaultSceneID = "sidebar"
}

public struct CMUXSidebarExtensionRecord: Equatable, Identifiable, Sendable {
    public var id: String { manifest.id }
    public var manifest: CMUXExtensionManifest
    public var isHostProvided: Bool

    public init(manifest: CMUXExtensionManifest, isHostProvided: Bool) {
        self.manifest = manifest
        self.isHostProvided = isHostProvided
    }
}

public enum CMUXExtensionClientError: Error, Equatable, Sendable {
    case duplicateExtensionIdentifier(String)
    case extensionNotFound(String)
}

public struct CMUXSidebarExtensionRegistry: Sendable {
    private var recordsByID: [String: CMUXSidebarExtensionRecord]

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

    public var records: [CMUXSidebarExtensionRecord] {
        recordsByID.values.sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    public func record(id: String) throws -> CMUXSidebarExtensionRecord {
        guard let record = recordsByID[id] else {
            throw CMUXExtensionClientError.extensionNotFound(id)
        }
        return record
    }
}

public actor CMUXSidebarExtensionSession {
    private let manifest: CMUXExtensionManifest
    private let client: CMUXSidebarHostClient
    private var latestSnapshot: CMUXSidebarSnapshot?

    public init(manifest: CMUXExtensionManifest, client: CMUXSidebarHostClient) throws {
        try CMUXExtensionValidator.validateSidebarManifest(manifest)
        self.manifest = manifest
        self.client = client
    }

    public func refreshSnapshot() async throws -> CMUXSidebarSnapshot {
        let snapshot = try await client.snapshot()
        latestSnapshot = snapshot
        return snapshot
    }

    public func perform(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult {
        try await client.dispatch(action)
    }

    public var extensionManifest: CMUXExtensionManifest {
        manifest
    }

    public func cachedSnapshot() -> CMUXSidebarSnapshot? {
        latestSnapshot
    }
}

public struct CMUXInstalledSidebarExtension: Identifiable, Equatable, Sendable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var localizedName: String
    public var extensionPointIdentifier: String

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
public struct CMUXSidebarExtensionDiscovery {
    public init() {}

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
public struct CMUXSidebarExtensionHostView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = EXHostViewController

    private let identity: AppExtensionIdentity
    private let sceneID: String

    public init(identity: AppExtensionIdentity, sceneID: String = CMUXSidebarExtensionPoint.defaultSceneID) {
        self.identity = identity
        self.sceneID = sceneID
    }

    public func makeNSViewController(context: Context) -> EXHostViewController {
        let viewController = EXHostViewController()
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
        return viewController
    }

    public func updateNSViewController(_ viewController: EXHostViewController, context: Context) {
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
    }
}
