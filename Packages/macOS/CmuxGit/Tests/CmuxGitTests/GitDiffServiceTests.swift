import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceTests {
    @Test func mergesSeparateNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "3\t1\tSources/App.swift\0-\t-\tAssets/image.png\0",
            nameStatusOutput: "M\0Sources/App.swift\0A\0Assets/image.png\0",
            untrackedOutput: nil
        )

        #expect(files.count == 2)
        let app = try! #require(files.first { $0.path == "Sources/App.swift" })
        #expect(app.status == .modified)
        #expect(app.additions == 3)
        #expect(app.deletions == 1)

        let binary = try! #require(files.first { $0.path == "Assets/image.png" })
        #expect(binary.status == .added)
        #expect(binary.additions == nil)
        #expect(binary.deletions == nil)
    }

    @Test func mergesRenameNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "2\t4\t\0Old.swift\0New.swift\0",
            nameStatusOutput: "R100\0Old.swift\0New.swift\0",
            untrackedOutput: nil
        )

        let renamed = try! #require(files.first)
        #expect(files.count == 1)
        #expect(renamed.path == "New.swift")
        #expect(renamed.oldPath == "Old.swift")
        #expect(renamed.status == .renamed)
        #expect(renamed.additions == 2)
        #expect(renamed.deletions == 4)
    }

    @Test func addsUntrackedFilesWithoutCounts() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "",
            nameStatusOutput: "",
            untrackedOutput: "Scratch.md\0"
        )

        let untracked = try! #require(files.first)
        #expect(untracked.path == "Scratch.md")
        #expect(untracked.status == .untracked)
        #expect(untracked.additions == nil)
        #expect(untracked.deletions == nil)
    }
}
