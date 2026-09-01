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
            under: ArtifactStorePaths(projectRoot: root).filesystemRoot
        )
        let repository = LocalArtifactRepository(maximumScanDepth: 1)

        let node = try await repository.resolve(
            projectRoot: root,
            name: "one/two/target.md"
        )

        #expect(node.relativePath == "one/two/target.md")
    }

    @Test("Exact paths cannot expose cmux-managed metadata")
    func exactResolutionHidesManagedMetadata() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let metadata = try ArtifactTestSupport.write(
            #"{"sourcePath":"/tmp/private"}"#,
            named: ".metadata/provenance/private.json",
            under: ArtifactStorePaths(projectRoot: root).filesystemRoot
        )

        await #expect(throws: ArtifactStoreError.artifactNotFound(
            ".metadata/provenance/private.json"
        )) {
            _ = try await LocalArtifactRepository().resolve(
                projectRoot: root,
                name: ".metadata/provenance/private.json"
            )
        }
        #expect(FileManager.default.fileExists(atPath: metadata.path))
    }

    @Test("Bounded repository snapshots and searches fail instead of appearing complete")
    func incompleteScansFailExplicitly() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let artifactRoot = ArtifactStorePaths(projectRoot: root).filesystemRoot
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

    @Test("Tree snapshots retain identity across same-path replacements with preserved mtime")
    func snapshotsDistinguishSamePathReplacement() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        let file = paths.filesystemRoot.appendingPathComponent("preview.png", isDirectory: false)
        let fixedDate = Date(timeIntervalSince1970: 1_234_567)
        _ = try ArtifactTestSupport.write("first", named: "preview.png", under: paths.filesystemRoot)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: file.path
        )
        let scanner = ArtifactTreeScanner(
            fileManager: .default,
            maximumDepth: 4,
            nodeBudget: 100
        )
        let firstNode = try #require(scanner.snapshot(paths: paths).nodes.first)

        _ = try ArtifactTestSupport.write("second", named: "preview.png", under: paths.filesystemRoot)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: file.path
        )
        let secondNode = try #require(scanner.snapshot(paths: paths).nodes.first)

        #expect(firstNode.modifiedAt == secondNode.modifiedAt)
        #expect(firstNode.fileIdentity != nil)
        #expect(secondNode.fileIdentity != nil)
        #expect(firstNode.fileIdentity != secondNode.fileIdentity)
    }

    @MainActor
    @Test("The sidebar reports a bounded partial tree as a load failure")
    func sidebarRejectsIncompleteTree() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        _ = try ArtifactTestSupport.write(
            "target",
            named: "one/two/target.md",
            under: ArtifactStorePaths(projectRoot: root).filesystemRoot
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
