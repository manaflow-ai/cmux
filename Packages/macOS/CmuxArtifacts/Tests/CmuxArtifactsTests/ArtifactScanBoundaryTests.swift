import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact scan boundaries")
struct ArtifactScanBoundaryTests {
    @Test("Exact relative paths resolve without a recursive tree scan")
    func resolvesExactRelativePathBeyondDepthBudget() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        _ = try ArtifactTestSupport.write(
            "target",
            named: "one/two/target.md",
            under: ArtifactStorePaths(projectRoot: root).artifactsRoot
        )
        let repository = LocalArtifactRepository(maximumScanDepth: 1)

        let node = try await repository.resolve(
            projectRoot: root,
            name: "one/two/target.md"
        )

        #expect(node.relativePath == "one/two/target.md")
    }

    @Test("Bounded repository snapshots and searches fail instead of appearing complete")
    func incompleteScansFailExplicitly() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let artifactRoot = ArtifactStorePaths(projectRoot: root).artifactsRoot
        _ = try ArtifactTestSupport.write("one", named: "one.md", under: artifactRoot)
        _ = try ArtifactTestSupport.write("two", named: "two.md", under: artifactRoot)
        let repository = LocalArtifactRepository(nodeBudget: 1)

        await #expect(throws: ArtifactStoreError.scanIncomplete(artifactRoot.path)) {
            _ = try await repository.snapshot(projectRoot: root)
        }
        await #expect(throws: ArtifactStoreError.scanIncomplete(artifactRoot.path)) {
            _ = try await repository.search(projectRoot: root, query: "one")
        }
    }

    @MainActor
    @Test("The sidebar reports a bounded partial tree as a load failure")
    func sidebarRejectsIncompleteTree() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        _ = try ArtifactTestSupport.write(
            "target",
            named: "one/two/target.md",
            under: ArtifactStorePaths(projectRoot: root).artifactsRoot
        )
        let repository = LocalArtifactRepository(maximumScanDepth: 1)
        let model = ArtifactSidebarModel(
            store: repository,
            captureService: ArtifactCaptureService(store: repository),
            searchDebounce: .zero
        )

        await model.bind(workspace: ArtifactSidebarWorkspace(
            id: "workspace",
            title: "Workspace",
            workingDirectory: root
        ))

        #expect(model.phase == .failed)
    }
}
