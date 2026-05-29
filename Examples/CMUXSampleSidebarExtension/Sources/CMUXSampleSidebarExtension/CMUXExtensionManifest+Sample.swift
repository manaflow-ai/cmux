import CmuxExtensionKit
import Foundation

public extension CMUXExtensionManifest {
    static let cmuxSampleSidebar = CMUXExtensionManifest(
        id: "com.manaflow.cmux.samples.sidebar",
        displayName: "CMUX Sample Sidebar",
        kind: .sidebar,
        minimumAPIVersion: .sidebarV1,
        requestedScopes: [
            .workspaceMetadata,
            .workspacePaths,
            .notifications,
            .networkPorts,
            .pullRequests,
        ]
    )
}
