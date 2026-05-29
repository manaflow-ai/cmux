import CmuxExtensionKit
import XCTest
@testable import CMUXExtensionClient

final class CMUXExtensionClientTests: XCTestCase {
    func testRegistrySortsAndRejectsDuplicates() throws {
        let first = CMUXSidebarExtensionRecord(
            manifest: CMUXExtensionManifest(id: "b", displayName: "Browser Stack"),
            isHostProvided: false
        )
        let second = CMUXSidebarExtensionRecord(
            manifest: CMUXExtensionManifest(id: "a", displayName: "Attention Queue"),
            isHostProvided: false
        )

        let registry = try CMUXSidebarExtensionRegistry(records: [first, second])
        XCTAssertEqual(registry.records.map(\.id), ["a", "b"])

        XCTAssertThrowsError(try CMUXSidebarExtensionRegistry(records: [first, first])) { error in
            XCTAssertEqual(error as? CMUXExtensionClientError, .duplicateExtensionIdentifier("b"))
        }
    }

    func testSidebarExtensionPointUsesStablePublicIdentifiers() {
        XCTAssertEqual(CMUXSidebarExtensionPoint.identifier, "com.manaflow.cmux.sidebar")
        XCTAssertEqual(CMUXSidebarExtensionPoint.defaultSceneID, "sidebar")
    }

    func testSessionRefreshesSnapshotAndDispatchesActions() async throws {
        let workspaceID = UUID()
        let snapshot = CMUXSidebarSnapshot(
            sequence: 7,
            selectedWorkspaceID: workspaceID,
            workspaces: [CMUXSidebarWorkspace(id: workspaceID, title: "One")]
        )
        let recorder = ActionRecorder()
        let client = CMUXSidebarHostClient(
            snapshot: { snapshot },
            dispatch: { action in
                await recorder.append(action)
                return .accepted
            }
        )
        let session = try CMUXSidebarExtensionSession(
            manifest: CMUXExtensionManifest(id: "dev.example.sidebar", displayName: "Example"),
            client: client
        )

        let refreshed = try await session.refreshSnapshot()
        let result = try await session.perform(.selectWorkspace(workspaceID))

        XCTAssertEqual(refreshed, snapshot)
        let cached = await session.cachedSnapshot()
        let actions = await recorder.actions()
        XCTAssertEqual(cached, snapshot)
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(actions, [.selectWorkspace(workspaceID)])
    }
}

private actor ActionRecorder {
    private var storage: [CMUXSidebarAction] = []

    func append(_ action: CMUXSidebarAction) {
        storage.append(action)
    }

    func actions() -> [CMUXSidebarAction] {
        storage
    }
}
