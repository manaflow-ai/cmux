import Testing

@testable import CmuxMobileChanges

@Suite struct ChangedFilesTreeTests {
    private func item(_ path: String, kind: FileChangeKind = .modified, oldPath: String? = nil) -> ChangedFileItem {
        ChangedFileItem(path: path, oldPath: oldPath, kind: kind, additions: 1, deletions: 0, isBinary: false)
    }

    private func rows(_ files: [ChangedFileItem], collapsed: Set<String> = []) -> [ChangedFilesTreeRow] {
        ChangedFilesTree.build(from: files).rows(collapsedDirectories: collapsed)
    }

    @Test func groupsFilesUnderTheirDirectoriesWithDirectoriesFirst() {
        let rows = rows([item("README.md"), item("Sources/A.swift"), item("Sources/B.swift")])

        #expect(rows.map(\.id) == [
            "dir:Sources",
            "file:Sources/A.swift",
            "file:Sources/B.swift",
            "file:README.md",
        ])
        guard case .directory(let sources) = rows[0], case .file(let nested) = rows[1],
              case .file(let root) = rows[3] else {
            Issue.record("unexpected row kinds: \(rows)")
            return
        }
        #expect(sources.depth == 0)
        #expect(sources.isExpanded)
        #expect(nested.depth == 1)
        #expect(root.depth == 0)
    }

    @Test func flattensSingleChildDirectoryChainsIntoOneRow() {
        let rows = rows([item("a/b/c/First.swift"), item("a/b/c/Second.swift")])

        guard case .directory(let chain) = rows.first else {
            Issue.record("expected a leading directory row")
            return
        }
        #expect(chain.path == "a/b/c")
        #expect(chain.displayName == "a/b/c")
        #expect(chain.depth == 0)
        #expect(rows.count == 3)
        guard case .file(let leaf) = rows[1] else {
            Issue.record("expected a file row under the flattened chain")
            return
        }
        #expect(leaf.depth == 1)
    }

    @Test func chainFlatteningStopsWhereADirectoryBranchesOrHoldsFiles() {
        let rows = rows([item("a/b/Here.swift"), item("a/b/c/Deep.swift")])

        #expect(rows.map(\.id) == [
            "dir:a/b",
            "dir:a/b/c",
            "file:a/b/c/Deep.swift",
            "file:a/b/Here.swift",
        ])
        guard case .directory(let inner) = rows[1], case .file(let deep) = rows[2],
              case .file(let here) = rows[3] else {
            Issue.record("unexpected row kinds: \(rows)")
            return
        }
        #expect(inner.depth == 1)
        #expect(deep.depth == 2)
        #expect(here.depth == 1)
    }

    @Test func siblingsSortDirectoriesFirstThenCaseInsensitively() {
        let rows = rows([
            item("zeta.swift"),
            item("beta/y.swift"),
            item("Alpha/x.swift"),
            item("Gamma.swift"),
        ])

        #expect(rows.map(\.id) == [
            "dir:Alpha",
            "file:Alpha/x.swift",
            "dir:beta",
            "file:beta/y.swift",
            "file:Gamma.swift",
            "file:zeta.swift",
        ])
    }

    @Test func fileRowsKeepTheirFlatSnapshotIndices() {
        let files = [item("b/two.swift"), item("a/one.swift"), item("root.swift")]

        let indicesByPath = rows(files).reduce(into: [String: Int]()) { result, row in
            if case .file(let file) = row {
                result[file.snapshot.file.path] = file.snapshot.index
            }
        }
        #expect(indicesByPath == ["b/two.swift": 0, "a/one.swift": 1, "root.swift": 2])
    }

    @Test func collapsingADirectoryHidesEveryDescendantRow() {
        let files = [item("Sources/UI/View.swift"), item("Sources/Model.swift"), item("README.md")]

        let rows = rows(files, collapsed: ["Sources"])
        #expect(rows.map(\.id) == ["dir:Sources", "file:README.md"])
        guard case .directory(let sources) = rows[0] else {
            Issue.record("expected a directory row")
            return
        }
        #expect(!sources.isExpanded)
        #expect(sources.fileCount == 2)
    }

    @Test func collapsingANestedDirectoryKeepsItsSiblingsVisible() {
        let files = [item("Sources/UI/View.swift"), item("Sources/Model.swift"), item("README.md")]

        let rows = rows(files, collapsed: ["Sources/UI"])
        #expect(rows.map(\.id) == [
            "dir:Sources",
            "dir:Sources/UI",
            "file:Sources/Model.swift",
            "file:README.md",
        ])
    }

    @Test func renamedFileSitsUnderItsNewDirectory() {
        let rows = rows([item("New/Name.swift", kind: .renamed, oldPath: "Old/Name.swift")])

        #expect(rows.map(\.id) == ["dir:New", "file:New/Name.swift"])
    }

    @Test func deletedFileAndSameNamedNewDirectoryKeepDistinctIdentities() {
        let rows = rows([item("a", kind: .deleted), item("a/b.swift", kind: .added)])

        #expect(rows.map(\.id) == ["dir:a", "file:a/b.swift", "file:a"])
    }

    @Test func everythingStartsExpandedWithNoCollapsedState() {
        let files = [item("a/b/File.swift"), item("a/c/Other.swift")]

        let visibleFiles = rows(files).filter {
            if case .file = $0 { return true }
            return false
        }
        #expect(visibleFiles.count == files.count)
    }
}
