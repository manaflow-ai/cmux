import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact project locator")
struct ArtifactProjectLocatorTests {
    @Test("Nearest cmux directory wins over an outer Git root")
    func locatesNearestCmuxDirectory() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let project = root.appendingPathComponent("nested/project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".cmux"), withIntermediateDirectories: true)
        let child = project.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let located = ArtifactProjectLocator().projectRoot(startingAt: child, fileManager: .default)

        #expect(located == project.standardizedFileURL)
    }

    @Test("A nested Git project wins over an outer cmux directory")
    func locatesNearestGitDirectory() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".cmux"),
            withIntermediateDirectories: true
        )
        let project = root.appendingPathComponent("nested/project")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let child = project.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let located = ArtifactProjectLocator().projectRoot(startingAt: child, fileManager: .default)

        #expect(located == project.standardizedFileURL)
    }

    @Test("Ancestor traversal reaches the filesystem root exactly once")
    func traversesToRootOnce() {
        let ancestors = Array(
            ArtifactAncestorDirectories(startingAt: URL(fileURLWithPath: "/alpha/beta", isDirectory: true))
        )

        #expect(ancestors.map(\.path) == ["/alpha/beta", "/alpha", "/"])
    }

    @Test("A directory without project markers falls back to itself")
    func fallsBackWithoutMarkers() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let child = root.appendingPathComponent("nested/project", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let located = ArtifactProjectLocator().projectRoot(startingAt: child, fileManager: .default)

        #expect(located == child.standardizedFileURL)
    }
}
