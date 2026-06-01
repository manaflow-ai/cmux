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
        #expect(CMUXSidebarExtensionPoint.baseIdentifier == "com.manaflow.cmux.sidebar")
        // No Info.plist override in the test bundle, so it resolves to the base id.
        #expect(CMUXSidebarExtensionPoint.identifier(in: .main) == "com.manaflow.cmux.sidebar")
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
            manifest: CMUXExtensionManifest(
                id: "dev.example.sidebar",
                displayName: "Example",
                requestedScopes: [.workspaceMetadata],
                requestedActionScopes: [.selectWorkspace]
            ),
            client: client,
            grantedActionScopes: [.selectWorkspace]
        )

        let refreshed = try await session.refreshSnapshot()
        let result = try await session.perform(.selectWorkspace(workspaceID))

        let cached = await session.cachedSnapshot()
        let actions = await recorder.actions()
        #expect(refreshed.workspaces == snapshot.workspaces)
        #expect(refreshed.grantedReadScopes == [.workspaceMetadata])
        #expect(refreshed.grantedActionScopes == [.selectWorkspace])
        #expect(cached == refreshed)
        #expect(result == .accepted)
        #expect(actions == [.selectWorkspace(workspaceID)])
    }

    @Test
    func testSessionFiltersSnapshotsAndRejectsUngrantedActions() async throws {
        let workspaceID = UUID()
        let snapshot = CMUXSidebarSnapshot(
            sequence: 8,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: [.workspaceMetadata, .workspacePaths],
            grantedActionScopes: [.selectWorkspace],
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Private",
                    rootPath: "/Users/example/private",
                    projectRootPath: "/Users/example/private"
                ),
            ]
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
            manifest: CMUXExtensionManifest(
                id: "dev.example.sidebar",
                displayName: "Example",
                requestedScopes: [.workspaceMetadata, .workspacePaths],
                requestedActionScopes: [.selectWorkspace, .closeWorkspace]
            ),
            client: client,
            grantedReadScopes: [.workspaceMetadata],
            grantedActionScopes: [.selectWorkspace]
        )

        let filtered = try await session.refreshSnapshot()
        let workspace = try #require(filtered.workspaces.first)
        let rejected = try await session.perform(.closeWorkspace(workspaceID))
        let accepted = try await session.perform(.selectWorkspace(workspaceID))
        let actions = await recorder.actions()

        #expect(workspace.rootPath == nil)
        #expect(workspace.projectRootPath == nil)
        #expect(filtered.grantedReadScopes == [.workspaceMetadata])
        #expect(filtered.grantedActionScopes == [.selectWorkspace])
        #expect(!rejected.accepted)
        #expect(rejected.message == "Extension action is not granted")
        #expect(accepted == .accepted)
        #expect(actions == [.selectWorkspace(workspaceID)])
    }

    @Test
    func testSessionRequiresOpenURLForURLBearingBrowserCreation() async throws {
        let workspaceID = UUID()
        let emptyAction = CMUXSidebarAction.createBrowserSurface(workspaceID: workspaceID, url: nil)
        let urlAction = CMUXSidebarAction.createBrowserSurface(workspaceID: workspaceID, url: "https://example.com")
        let recorder = ActionRecorder()
        let client = CMUXSidebarHostClient(
            snapshot: {
                CMUXSidebarSnapshot(sequence: 1, selectedWorkspaceID: nil, workspaces: [])
            },
            dispatch: { action in
                await recorder.append(action)
                return .accepted
            }
        )
        let session = try CMUXSidebarExtensionSession(
            manifest: CMUXExtensionManifest(
                id: "dev.example.sidebar",
                displayName: "Example",
                requestedActionScopes: [.createSurface, .openURL]
            ),
            client: client,
            grantedActionScopes: [.createSurface]
        )

        let emptyBrowser = try await session.perform(emptyAction)
        let urlBrowser = try await session.perform(urlAction)
        let actions = await recorder.actions()

        #expect(emptyBrowser == .accepted)
        #expect(!urlBrowser.accepted)
        #expect(urlBrowser.message == "Extension action is not granted")
        #expect(actions == [emptyAction])
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
