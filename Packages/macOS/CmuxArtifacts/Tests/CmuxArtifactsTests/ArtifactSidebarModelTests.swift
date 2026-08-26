import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact sidebar model")
@MainActor
struct ArtifactSidebarModelTests {
    @Test("Model teardown is safe when its final reference is released off the main actor")
    nonisolated func releasesOffMainActor() async {
        await Task.detached {
            let model = await MainActor.run {
                ArtifactSidebarModel(
                    store: SidebarArtifactStore(
                        root: URL(fileURLWithPath: "/tmp/artifact-sidebar-release-test"),
                        nodes: []
                    ),
                    captureService: SidebarCaptureSpy()
                )
            }

            withExtendedLifetime(model) {}
        }.value
    }

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
        #expect(model.rows.allSatisfy { $0.projectRoot == root.standardizedFileURL })
    }

    @Test("Binding scans once while installing the initial filesystem watcher")
    func bindingScansOnce() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let store = SidebarArtifactStore(root: root, nodes: [])
        let model = ArtifactSidebarModel(store: store, captureService: SidebarCaptureSpy())

        await model.bind(workspace: workspace(root: root))

        #expect(await store.waitUntilWatching())
        #expect(await store.settledSnapshotCount() == 1)
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

    @Test("Watcher coalesces a burst into one bounded reload")
    func coalescesWatcherBurst() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let store = SidebarArtifactStore(root: root, nodes: [])
        let model = ArtifactSidebarModel(
            store: store,
            captureService: SidebarCaptureSpy(),
            watcherDebounce: .milliseconds(50)
        )
        await model.bind(workspace: workspace(root: root))
        #expect(await store.waitUntilWatching())
        let baseline = await store.snapshotCount

        for index in 0..<20 {
            let node = ArtifactTestSupport.artifactNode(
                root: root,
                relativePath: "burst-\(index).md",
                kind: .markdown
            )
            await store.replaceNodes([node], notify: true)
        }

        #expect(await store.settledSnapshotCount() == baseline + 1)
    }

    @Test("Same-path file changes update the immutable thumbnail revision")
    func fileChangesUpdateThumbnailRevision() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let first = ArtifactTestSupport.artifactNode(
            root: root,
            relativePath: "preview.png",
            kind: .image,
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileIdentity: ArtifactFileIdentity(device: 1, inode: 10)
        )
        let second = ArtifactTestSupport.artifactNode(
            root: root,
            relativePath: "preview.png",
            kind: .image,
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileIdentity: ArtifactFileIdentity(device: 1, inode: 11)
        )
        let store = SidebarArtifactStore(root: root, nodes: [first])
        let model = ArtifactSidebarModel(store: store, captureService: SidebarCaptureSpy())
        await model.bind(workspace: workspace(root: root))
        #expect(await store.waitUntilWatching())
        let firstRows = model.rows

        await store.replaceNodes([second], notify: true)

        #expect(await waitUntil { model.rows != firstRows })
    }

    @Test("Thumbnail revisions include file identity as well as modification time")
    func thumbnailRevisionIncludesFileIdentity() {
        let modifiedAt = Date(timeIntervalSince1970: 1)

        #expect(
            ArtifactSidebarFileRevision(
                fileURL: URL(fileURLWithPath: "/tmp/preview.png"),
                modifiedAt: modifiedAt,
                fileIdentity: ArtifactFileIdentity(device: 1, inode: 10)
            ) != ArtifactSidebarFileRevision(
                fileURL: URL(fileURLWithPath: "/tmp/preview.png"),
                modifiedAt: modifiedAt,
                fileIdentity: ArtifactFileIdentity(device: 1, inode: 11)
            )
        )
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

        #expect(await capture.addedSourceURLs == [source])
        #expect(await capture.lastContext?.projectRoot == root.standardizedFileURL)
        #expect(await capture.lastContext?.workspaceID == "workspace-1")
        #expect(await capture.lastContext?.workspaceTitle == "Artifacts Test")
    }

    @Test("Manual multi-select submits one batch, continues after rejection, and reloads once")
    func addsSelectionAsOneBatch() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let rejected = root.appendingPathComponent("rejected.exe")
        let accepted = root.appendingPathComponent("accepted.md")
        let store = SidebarArtifactStore(root: root, nodes: [])
        let capture = SidebarCaptureSpy(rejectedSourceURLs: [rejected])
        let model = ArtifactSidebarModel(store: store, captureService: capture)
        await model.bind(workspace: workspace(root: root))
        let snapshotCountBeforeAdd = await store.snapshotCount

        await model.addFiles([rejected, accepted])

        #expect(await capture.addCallCount == 1)
        #expect(await capture.addedSourceURLs == [rejected, accepted])
        #expect(await store.snapshotCount == snapshotCountBeforeAdd + 1)
        #expect(model.actionFailure == .add)
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
        #expect(await capture.lastContext?.workspaceTitle == "Renamed")
    }

    @Test("Workspace rebind clears stale rows before project resolution finishes")
    func rebindClearsRowsBeforeAwaitingResolution() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let oldFile = ArtifactTestSupport.artifactNode(
            root: root,
            relativePath: "old-session/private.md",
            kind: .markdown
        )
        let store = SidebarArtifactStore(root: root, nodes: [oldFile])
        let model = ArtifactSidebarModel(store: store, captureService: SidebarCaptureSpy())
        await model.bind(workspace: workspace(root: root))
        await store.suspendNextLocate()

        let rebind = Task { @MainActor in
            await model.bind(workspace: ArtifactSidebarWorkspace(
                id: "workspace-2",
                title: "Second Workspace",
                workingDirectory: root.appendingPathComponent("second", isDirectory: true)
            ))
        }
        await store.waitUntilLocateStarts()

        #expect(model.phase == .loading)
        #expect(model.rows.isEmpty)
        #expect(model.projectRoot == nil)

        await store.releaseLocate()
        await rebind.value
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
