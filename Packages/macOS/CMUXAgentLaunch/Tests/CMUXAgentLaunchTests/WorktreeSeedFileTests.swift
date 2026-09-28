import Foundation
import Testing
import CMUXAgentLaunch

@Suite("worktreeinclude files")
struct WorktreeSeedFileTests {
    @Test func theFileNameIsTheOneTheRepositoryRootUses() {
        #expect(WorktreeSeedFile.fileName == ".worktreeinclude")
    }

    @Test func patternsKeepFileOrderAndLineNumbers() {
        let file = WorktreeSeedFile.parse(
            """
            # what a fresh worktree needs
            .env

            link node_modules
            !.env.production
            """
        )
        #expect(file.problems.isEmpty)
        #expect(file.patterns.map(\.glob) == [".env", "node_modules", ".env.production"])
        #expect(file.patterns.map(\.line) == [2, 4, 5])
        #expect(file.patterns.map(\.action) == [.copy, .link, .copy])
        #expect(file.patterns.map(\.isNegated) == [false, false, true])
    }

    @Test func oneBadLineDoesNotDiscardTheGoodOnes() {
        let file = WorktreeSeedFile.parse(".env\n/absolute\nconfig/local.json\n")
        #expect(file.patterns.map(\.glob) == [".env", "config/local.json"])
        #expect(file.problems.count == 1)
        #expect(file.problems[0].line == 2)
        #expect(file.problems[0].reason == .leadingSlash)
    }

    @Test func everyBadLineIsReportedInOnePass() {
        let file = WorktreeSeedFile.parse("/one\n~two\n../three\n!link four\n")
        #expect(file.patterns.isEmpty)
        #expect(file.problems.map(\.line) == [1, 2, 3, 4])
        #expect(file.problems.map(\.reason) == [
            .leadingSlash, .homeRelative, .escapesRepository, .negatedActionKeyword,
        ])
    }

    @Test func aFileOfCommentsIsEmptyRatherThanBroken() {
        let file = WorktreeSeedFile.parse("# nothing here yet\n\n   \n")
        #expect(file.isEmpty)
        #expect(file.problems.isEmpty)
    }

    @Test func windowsLineEndingsDoNotBecomePartOfAFilename() {
        let file = WorktreeSeedFile.parse(".env\r\nlink node_modules\r\n")
        #expect(file.patterns.map(\.glob) == [".env", "node_modules"])
    }

    @Test func aFileWithoutATrailingNewlineKeepsItsLastPattern() {
        #expect(WorktreeSeedFile.parse(".env").patterns.count == 1)
    }

    @Test func anEmptyFileIsEmpty() {
        let file = WorktreeSeedFile.parse("")
        #expect(file.isEmpty)
        #expect(file.problems.isEmpty)
    }
}
