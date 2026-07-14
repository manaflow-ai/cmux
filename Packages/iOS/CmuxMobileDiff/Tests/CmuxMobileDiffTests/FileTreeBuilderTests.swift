import CmuxMobileRPC
import Testing

@testable import CmuxMobileDiff

@Suite struct FileTreeBuilderTests {
    @Test func buildsNestedDirectoriesAndCompressesSingleChildChains() throws {
        let roots = FileTreeBuilder().build(files: [
            file("src/app/utils/Format.swift"),
            file("src/app/utils/Parse.swift"),
        ])
        #expect(roots.count == 1)
        #expect(roots[0].name == "src/app/utils")
        #expect(roots[0].children.map(\.name) == ["Format.swift", "Parse.swift"])
    }

    @Test func sortsDirectoriesBeforeFilesThenAlphabetically() {
        let roots = FileTreeBuilder().build(files: [
            file("z.txt"),
            file("Beta/file.swift"),
            file("alpha/file.swift"),
            file("a.txt"),
        ])
        #expect(roots.map(\.name) == ["alpha", "Beta", "a.txt", "z.txt"])
        #expect(roots.prefix(2).allSatisfy { $0.kind == .directory })
    }

    @Test func preservesBranchingInsteadOfOverCompressing() throws {
        let roots = FileTreeBuilder().build(files: [file("src/a/A.swift"), file("src/b/B.swift")])
        let src = try #require(roots.first)
        #expect(src.name == "src")
        #expect(src.children.map(\.name) == ["a", "b"])
    }

    private func file(_ path: String) -> MobileChangesFile {
        MobileChangesFile(
            path: path,
            oldPath: nil,
            status: .modified,
            additions: 1,
            deletions: 1,
            isBinary: false,
            isLarge: false,
            patchDigest: path
        )
    }
}
