import CmuxExtensionKit
import Foundation

public struct CMUXSampleSidebarExtension: CMUXSidebarExtension {
    public let manifest: CMUXExtensionManifest
    private let snapshotProvider: @Sendable () async throws -> CMUXSidebarSnapshot

    public init(
        manifest: CMUXExtensionManifest = .cmuxSampleSidebar,
        snapshotProvider: @escaping @Sendable () async throws -> CMUXSidebarSnapshot = {
            CMUXSidebarSnapshot.sample
        }
    ) {
        self.manifest = manifest
        self.snapshotProvider = snapshotProvider
    }

    public func makeInitialSnapshot() async throws -> CMUXSidebarSnapshot {
        try await snapshotProvider()
    }

    public func handle(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult {
        switch action {
        case .selectWorkspace, .openURL:
            return .accepted
        case .closeWorkspace:
            return CMUXExtensionActionResult(
                accepted: false,
                message: "The sample sidebar does not close workspaces."
            )
        }
    }
}
