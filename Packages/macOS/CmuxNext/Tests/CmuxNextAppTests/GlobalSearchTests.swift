import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Search All Windows (⌥⌘F): every word of the query across every
/// terminal's text, matches as a palette page. Reads are stand-ins, so no
/// daemon runs here.
struct GlobalSearchTests {
    /// Never started: the stand-in reads below do not use it.
    private static let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-test.sock"))

    private static func target(_ tabID: String) -> TerminalTextSearch.Target {
        TerminalTextSearch.Target(tabID: tabID, surface: SurfaceID(rawValue: 1), connection: connection)
    }

    @Test func wordsAreLowercasedAndSplitOnWhitespace() {
        #expect(TerminalTextSearch.words("  Build\tFAILED  now ") == ["build", "failed", "now"])
        #expect(TerminalTextSearch.words("   ").isEmpty)
    }

    @Test func aLineMatchesWhenItHasEveryWordInAnyCase() {
        let lines = ["error: build failed", "Build ok", "  BUILD FAILED again  ", "failed", "", "error: build failed"]
        #expect(TerminalTextSearch.matches(in: lines, words: ["build", "failed"])
            == ["error: build failed", "BUILD FAILED again"])
        #expect(TerminalTextSearch.matches(in: lines, words: []).isEmpty)
    }

    @Test func eachTerminalKeepsItsNewestMatches() {
        let lines = (1...50).map { "line \($0) hit" }
        let found = TerminalTextSearch.matches(in: lines, words: ["hit"])
        #expect(found.count == TerminalTextSearch.perTerminal)
        #expect(found.first == "line 50 hit")
    }

    @Test func searchKeepsTerminalOrderAndStopsAtTheLimit() async {
        let text = ["a": ["x hit", "y hit"], "b": ["nothing"], "c": ["z hit", "w hit", "v hit"]]
        let found = await TerminalTextSearch.search([Self.target("a"), Self.target("b"), Self.target("c")],
                                                    words: ["hit"], limit: 3) { text[$0.tabID] ?? [] }
        #expect(found.matches.map(\.tabID) == ["a", "c"])
        #expect(found.matches.map(\.lines) == [["y hit", "x hit"], ["v hit"]])
        #expect(found.limited)

        let all = await TerminalTextSearch.search([Self.target("a")], words: ["hit"], limit: 3) { text[$0.tabID] ?? [] }
        #expect(!all.limited)
    }

    @Test func theFindNeedleIsTheFirstWordAsTheLineSpellsIt() {
        #expect(GlobalSearchPage.needle(in: "Build FAILED", words: ["failed", "build"]) == "FAILED")
        #expect(GlobalSearchPage.needle(in: "x", words: []) == "")
    }

    @Test @MainActor func noMatchesShowsANotice() {
        let rows = GlobalSearchPage.items(for: [], limited: false, words: ["x"], terminals: []) { _, _ in }
        #expect(rows.map(\.title) == [GlobalSearchStrings.noMatches])
        #expect(rows.first?.isEnabled == false)
    }

    @Test @MainActor func theActionIsBoundAndAsksForText() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        #expect(registry.isBound("globalSearch"))
        #expect(registry.unavailableReason(for: "globalSearch") == nil)
        let descriptor = ActionCatalog.all.first { $0.id == "globalSearch" }
        #expect(descriptor?.arguments.map(\.name) == ["text"])
        #expect(descriptor?.surfaces.contains(.palette) == true)
    }
}
