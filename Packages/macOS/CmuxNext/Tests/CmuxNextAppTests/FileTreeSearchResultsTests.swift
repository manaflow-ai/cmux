@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Files search (Lucas 2026-10-17): the session host's `git.files.search` gives result paths relative
/// to the folder searched, the tab's, so they pass as they are (a tab in a subfolder of the repository
/// or behind a symlink keeps its matches); one that is absolute or steps out is dropped.
struct FileTreeSearchResultsTests {
    private func results(_ paths: [String]) -> [JSONValue] { paths.map { ["path": .string($0)] } }

    @Test func pathsRelativeToTheTabsFolderPassAsTheyAre() {
        #expect(FileTreePageProvider.searchResults(results(["src/App.tsx", "a/b.ts", "README.md"]))
            == ["src/App.tsx", "a/b.ts", "README.md"])
    }

    @Test func aPathThatLeavesTheFolderIsDropped() {
        #expect(FileTreePageProvider.searchResults(results(["/etc/passwd", "../secret", "a/../b", "./c", "d//e", ""])).isEmpty)
    }
}
