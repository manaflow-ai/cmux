import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDiffTreeTests {
    @Test func groupsDirectoriesAndPreservesStatusOrder() throws {
        let files = [
            change("README.md"),
            change("Sources/App.swift"),
            change("Sources/Models/User.swift"),
            change("Sources/Models/Team.swift"),
        ]

        let tree = MobileDiffTree(files: files)
        #expect(tree.rootFiles.map(\.path) == ["README.md"])
        let sources = try #require(tree.roots.first)
        #expect(sources.path == "Sources")
        #expect(sources.fileCount == 3)
        #expect(sources.files.map(\.path) == ["Sources/App.swift"])
        #expect(sources.directories.first?.files.map(\.path) == [
            "Sources/Models/User.swift",
            "Sources/Models/Team.swift",
        ])
    }

    @Test func collapseHidesOnlyDirectoryDescendants() {
        let tree = MobileDiffTree(files: [
            change("Root.swift"),
            change("Sources/App.swift"),
            change("Sources/Models/User.swift"),
        ])

        let visible = tree.visibleRows(collapsedDirectories: ["Sources"])
        #expect(visible.count == 2)
        #expect(visible[0].id == "file:Root.swift")
        #expect(visible[1].id == "directory:Sources")
    }

    private func change(_ path: String) -> MobileDiffFileChange {
        MobileDiffFileChange(path: path, status: "M", additions: 1, deletions: 1)
    }
}
