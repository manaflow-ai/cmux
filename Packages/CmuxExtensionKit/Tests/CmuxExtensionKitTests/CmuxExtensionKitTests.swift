import Foundation
import Testing
@testable import CmuxExtensionKit

@Suite
struct CMUXExtensionKitTests {
    @Test
    func testSidebarSnapshotRoundTripsStableContract() throws {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 42,
            windowID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Build",
                    detail: "main",
                    isPinned: true,
                    rootPath: "/repo",
                    projectRootPath: "/repo",
                    gitBranch: "main",
                    unreadCount: 2,
                    latestNotification: "Tests passed",
                    listeningPorts: [3000],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/1"]
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CMUXSidebarSnapshot.self, from: encoded)

        #expect(decoded == snapshot)
        #expect(decoded.apiVersion == CMUXExtensionAPIVersion.sidebarV1)
    }

    @Test
    func testManifestValidationAcceptsSidebarV1() throws {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            requestedScopes: [.workspaceMetadata, .workspacePaths]
        )

        try CMUXExtensionValidator.validateSidebarManifest(manifest)
    }

    @Test
    func testSidebarXPCCodecRoundTripsSnapshotActionAndResult() throws {
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 43,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Build",
                    detail: "Running tests",
                    isPinned: true,
                    rootPath: "/tmp/cmux",
                    projectRootPath: "/tmp/cmux",
                    gitBranch: "feature/sidebar",
                    unreadCount: 2,
                    latestNotification: "Tests failed",
                    listeningPorts: [3000],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/4994"]
                ),
            ]
        )
        let decodedSnapshot = try CMUXSidebarXPCCodec.decodeSnapshot(
            try CMUXSidebarXPCCodec.encodeSnapshot(snapshot)
        )
        #expect(decodedSnapshot == snapshot)

        let action = CMUXSidebarAction.selectWorkspace(workspaceID)
        let decodedAction = try CMUXSidebarXPCCodec.decodeAction(
            try CMUXSidebarXPCCodec.encodeAction(action)
        )
        #expect(decodedAction == action)

        let result = CMUXExtensionActionResult(accepted: false, message: "Not found")
        let decodedResult = try CMUXSidebarXPCCodec.decodeActionResult(
            try CMUXSidebarXPCCodec.encodeActionResult(result)
        )
        #expect(decodedResult == result)
    }

    @Test
    func testManifestValidationRejectsUnsupportedAPIVersion() {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            minimumAPIVersion: CMUXExtensionAPIVersion(major: 1, minor: 1)
        )

        do {
            try CMUXExtensionValidator.validateSidebarManifest(manifest)
            Issue.record("Expected unsupported API version error")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .unsupportedAPIVersion(
                    requested: CMUXExtensionAPIVersion(major: 1, minor: 1),
                    supported: .sidebarV1
                )
            )
        }
    }
}
