import Foundation
import Observation
import SwiftUI
import CmuxExtensionKit

@Observable
@MainActor
final class SidebarConnectionModel: @unchecked Sendable {
    static let shared = SidebarConnectionModel()
    static let manifest = CMUXExtensionManifest(
        id: "co.manaflow.CMUXExtKitSampleSidebarApp.Extension",
        displayName: "CMUX Sample Sidebar Extension",
        requestedScopes: [
            .workspaceMetadata,
            .workspacePaths,
            .notifications,
            .networkPorts,
            .pullRequests,
        ],
        requestedActionScopes: [
            .selectWorkspace,
        ]
    )

    private(set) var snapshot: CMUXSidebarSnapshot?
    private(set) var errorText: String?

    @ObservationIgnored
    private lazy var extensionConnection = CMUXSidebarExtensionConnection(
        manifest: Self.manifest,
        onSnapshot: { [weak self] snapshot in
            self?.snapshot = snapshot
        },
        onError: { [weak self] message in
            self?.errorText = message.map(Self.localizedHostMessage)
        }
    )

    private init() {}

    func accept(connection: NSXPCConnection) -> Bool {
        extensionConnection.accept(connection)
    }

    var insights: SidebarInsightModel? {
        snapshot.map(SidebarInsightModel.init(snapshot:))
    }

    func refreshSnapshot() {
        extensionConnection.refreshSnapshot()
    }

    func selectWorkspace(_ id: UUID) {
        extensionConnection.perform(.selectWorkspace(id))
    }

    private static func localizedHostMessage(_ message: String) -> String {
        switch message {
        case "Waiting for cmux":
            return String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux")
        case "cmux did not send a workspace snapshot":
            return String(localized: "sampleSidebar.emptySnapshot", defaultValue: "cmux did not send a workspace snapshot")
        default:
            return message
        }
    }
}
