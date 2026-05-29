import XCTest
@testable import CmuxExtensionKit

final class CMUXExtensionKitTests: XCTestCase {
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

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.apiVersion, .sidebarV1)
    }

    func testManifestValidationAcceptsSidebarV1() throws {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            requestedScopes: [.workspaceMetadata, .workspacePaths]
        )

        XCTAssertNoThrow(try CMUXExtensionValidator.validateSidebarManifest(manifest))
    }

    func testManifestValidationRejectsUnsupportedMajorVersion() {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            minimumAPIVersion: CMUXExtensionAPIVersion(major: 2, minor: 0)
        )

        XCTAssertThrowsError(try CMUXExtensionValidator.validateSidebarManifest(manifest)) { error in
            XCTAssertEqual(
                error as? CMUXExtensionValidationError,
                .unsupportedMajorVersion(requested: 2, supported: 1)
            )
        }
    }
}
