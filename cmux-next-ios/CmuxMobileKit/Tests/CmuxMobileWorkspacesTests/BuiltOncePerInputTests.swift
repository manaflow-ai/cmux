import Testing
@testable import CmuxMobileWorkspaces

/// The Workspaces list models its rows once per change of what they show, not once per body
/// pass: passes that change nothing the rows read model no row, at 1,000 workspaces as at 10.
@MainActor @Suite struct BuiltOncePerInputTests {
    private struct Input: Equatable {
        var inboxBuild: Int
        var unfolded: Set<String> = []
    }

    /// Rows modeled over `passes` body passes of which only the first sees new input.
    private func rowsModeled(workspaces: Int, passes: Int) -> (rows: Int, builds: Int) {
        let memo = BuiltOncePerInput<Input, [String]>()
        var rows = 0
        for _ in 0..<passes {
            _ = memo.value(Input(inboxBuild: 1)) {
                rows += workspaces
                return (0..<workspaces).map { "ws.\($0)" }
            }
        }
        return (rows, memo.builds)
    }

    @Test func passesWithTheSameInputModelTheRowsOnce() {
        let small = rowsModeled(workspaces: 10, passes: 50)
        let large = rowsModeled(workspaces: 1000, passes: 50)
        #expect(small.builds == 1)
        #expect(large.builds == 1)
        #expect(small.rows == 10)
        #expect(large.rows == 1000, "50 passes modeled \(large.rows) rows of 1,000 workspaces")
    }

    @Test func aChangedInputBuildsAgainAndOnlyThen() {
        let memo = BuiltOncePerInput<Input, Int>()
        #expect(memo.value(Input(inboxBuild: 1)) { 1 } == 1)
        #expect(memo.value(Input(inboxBuild: 1)) { 2 } == 1)
        #expect(memo.value(Input(inboxBuild: 2)) { 3 } == 3)
        #expect(memo.value(Input(inboxBuild: 2, unfolded: ["mac-1"])) { 4 } == 4)
        #expect(memo.builds == 3)
    }
}
