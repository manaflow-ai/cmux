import CmuxExtensionKit
import Foundation
import Testing
@testable import CMUXExtensionClient

@Suite
struct CMUXExtensionClientTests {
    @Test
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
        #expect(registry.records.map(\.id) == ["a", "b"])

        do {
            _ = try CMUXSidebarExtensionRegistry(records: [first, first])
            Issue.record("Expected duplicate extension identifier error")
        } catch {
            #expect(error as? CMUXExtensionClientError == .duplicateExtensionIdentifier("b"))
        }
    }

    @Test
    func testSidebarExtensionPointUsesStablePublicIdentifiers() {
        #expect(CMUXSidebarExtensionPoint.identifier == "com.manaflow.cmux.sidebar")
        #expect(CMUXSidebarExtensionPoint.defaultSceneID == "sidebar")
    }

    @Test
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

        let cached = await session.cachedSnapshot()
        let actions = await recorder.actions()
        #expect(refreshed == snapshot)
        #expect(cached == snapshot)
        #expect(result == .accepted)
        #expect(actions == [.selectWorkspace(workspaceID)])
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
