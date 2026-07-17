import CmuxMobileRPC
import Testing
@testable import CmuxDiffUI

@Suite struct DiffTreeBuilderTests {
    @Test func buildsDirectoriesAndFilesFromPathComponents() throws {
        let nodes = DiffTreeBuilder().build(files: [
            file("Sources/App.swift", .modified),
            file("Tests/AppTests.swift", .added),
        ])

        #expect(nodes.map(\.name) == ["Sources", "Tests"])
        let sources = try #require(nodes.first)
        #expect(sources.children.first?.name == "App.swift")
        #expect(sources.children.first?.kind == .file(.modified))
    }

    @Test func collapsesSingleChildDirectoryChainsButNotTheFile() throws {
        let nodes = DiffTreeBuilder().build(files: [
            file("Sources/Feature/Models/Item.swift", .modified),
        ])

        let directory = try #require(nodes.first)
        #expect(directory.name == "Sources/Feature/Models")
        #expect(directory.path == "Sources/Feature/Models")
        #expect(directory.children.map(\.name) == ["Item.swift"])
    }

    @Test func keepsBranchingDirectoriesExpanded() throws {
        let nodes = DiffTreeBuilder().build(files: [
            file("Sources/Feature/A.swift", .added),
            file("Sources/Feature/B.swift", .deleted),
        ])

        let directory = try #require(nodes.first)
        #expect(directory.name == "Sources/Feature")
        #expect(directory.children.map(\.name) == ["A.swift", "B.swift"])
    }

    private func file(_ path: String, _ status: MobileDiffFileStatus) -> DiffFileSnapshot {
        DiffFileSnapshot(
            summary: MobileDiffFileSummary(
                path: path,
                status: status,
                additions: 0,
                deletions: 0,
                isBinary: false,
                isLarge: false,
                patchDigest: "digest"
            ),
            content: .renameOnly
        )
    }
}
