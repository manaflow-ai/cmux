import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact sidebar model")
@MainActor
struct ArtifactSidebarModelTests {
    @Test("Binding projects an expanded immutable tree")
    func bindsExpandedTree() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let file = ArtifactTestSupport.artifactNode(root: root, relativePath: "session/plan.md", kind: .markdown)
        let folder = ArtifactTestSupport.artifactFolder(root: root, relativePath: "session", children: [file])
        let store = SidebarArtifactStore(root: root, nodes: [folder])
        let model = ArtifactSidebarModel(
            store: store,
            captureService: SidebarCaptureSpy(),
            searchDebounce: .zero
        )

        await model.bind(workspace: workspace(root: root))

        #expect(model.phase == .loaded)
        #expect(model.projectRoot == root.standardizedFileURL)
        #expect(model.rows.map(\.relativePath) == ["session", "session/plan.md"])
        #expect(model.rows.map(\.depth) == [0, 1])
    }

    @Test("Search replaces tree rows with content results")
    func searches() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let file = ArtifactTestSupport.artifactNode(root: root, relativePath: "notes.txt", kind: .text)
        let store = SidebarArtifactStore(root: root, nodes: [file])
        await store.setSearchResults([
            ArtifactSearchResult(node: file, score: 20, matchedContent: true, snippet: "needle here")
        ])
        let model = ArtifactSidebarModel(
            store: store,
            captureService: SidebarCaptureSpy(),
            searchDebounce: .zero
        )
        await model.bind(workspace: workspace(root: root))

        model.setQuery("needle")

        #expect(await waitUntil { model.rows.first?.snippet == "needle here" })
        #expect(model.rows.first?.matchedContent == true)
        #expect(await store.lastQuery == "needle")
    }

    @Test("Watcher updates rows after external filesystem changes")
    func watchesChanges() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let store = SidebarArtifactStore(root: root, nodes: [])
        let model = ArtifactSidebarModel(store: store, captureService: SidebarCaptureSpy())
        await model.bind(workspace: workspace(root: root))
        #expect(await store.waitUntilWatching())
        let appeared = ArtifactTestSupport.artifactNode(root: root, relativePath: "appeared.md", kind: .markdown)

        await store.replaceNodes([appeared], notify: true)

        #expect(await waitUntil { model.rows.map(\.relativePath) == ["appeared.md"] })
    }

    @Test("Manual add uses injected capture service and workspace context")
    func addsThroughCaptureService() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = root.appendingPathComponent("outside.md")
        let store = SidebarArtifactStore(root: root, nodes: [])
        let capture = SidebarCaptureSpy()
        let model = ArtifactSidebarModel(store: store, captureService: capture)
        await model.bind(workspace: workspace(root: root))

        await model.addFiles([source])

        let call = await capture.lastAdd
        #expect(call?.sourceURL == source)
        #expect(call?.context.projectRoot == root.standardizedFileURL)
        #expect(call?.context.workspaceID == "workspace-1")
        #expect(call?.context.workspaceTitle == "Artifacts Test")
    }

    @Test("Working-directory and title churn within one project does not rescan")
    func sameProjectWorkspaceUpdatesDoNotRescan() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let store = SidebarArtifactStore(root: root, nodes: [])
        let capture = SidebarCaptureSpy()
        let model = ArtifactSidebarModel(store: store, captureService: capture)
        await model.bind(workspace: workspace(root: root))
        let snapshotCountBeforeUpdate = await store.snapshotCount

        model.updateWorkspaceTitle(workspaceID: "workspace-1", title: "Renamed")
        await model.bind(workspace: ArtifactSidebarWorkspace(
            id: "workspace-1",
            title: "Renamed",
            workingDirectory: root.appendingPathComponent("nested/directory")
        ))
        let snapshotCountAfterUpdate = await store.snapshotCount
        await model.addFiles([root.appendingPathComponent("outside.md")])

        #expect(snapshotCountAfterUpdate == snapshotCountBeforeUpdate)
        #expect(await capture.lastAdd?.context.workspaceTitle == "Renamed")
    }

    private func workspace(root: URL) -> ArtifactSidebarWorkspace {
        ArtifactSidebarWorkspace(
            id: "workspace-1",
            title: "Artifacts Test",
            workingDirectory: root
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            // This is a bounded test deadline while waiting for an AsyncStream projection.
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
