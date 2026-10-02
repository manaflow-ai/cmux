import CmuxNextTerminalFind
import Testing

/// The terminal find bar's behavior against a Ghostty-like search: count,
/// next/previous with wrap, revealing a match up in scrollback, and Esc
/// cleanup (daily-driver dogfood of 00d5c8a974: no count, no next or
/// previous, no scroll to an off-screen match, a highlight left behind).
@Suite("Terminal find controller")
@MainActor
struct TerminalFindControllerTests {
    private func makeFind(_ matches: [String: Int] = ["error": 12]) -> (TerminalFindController, GhosttySearchStub) {
        let stub = GhosttySearchStub(matches: matches)
        let find = TerminalFindController(target: stub)
        stub.controller = find
        return (find, stub)
    }

    private func type(_ text: String, into find: TerminalFindController, _ stub: GhosttySearchStub) {
        var typed = ""
        for character in text {
            typed.append(character)
            find.updateQuery(typed)
        }
        stub.flush()
    }

    // MARK: Count

    @Test func typingSearchesLiveAndCountsTheSelectedMatch() {
        let (find, stub) = makeFind()
        find.open()
        type("error", into: find, stub)

        #expect(stub.calls.contains(.needle("e")))
        #expect(stub.needle == "error")
        #expect(find.count == .position(1, of: 12))

        find.navigate(.next)
        find.navigate(.next)
        stub.flush()
        #expect(find.count == .position(3, of: 12))
    }

    @Test func countSaysNoMatchesAndNothingForAnEmptyQuery() {
        let (find, stub) = makeFind()
        find.open()
        type("nope", into: find, stub)
        #expect(find.count == .noMatches)

        find.updateQuery("")
        stub.flush()
        #expect(stub.calls.last == .needle(""))
        #expect(!stub.isSearching)
        #expect(find.count == .empty)
    }

    @Test func aCaseOnlyEditKeepsTheCount() {
        let (find, stub) = makeFind()
        find.open()
        type("error", into: find, stub)
        find.updateQuery("Error")
        stub.flush()
        #expect(find.count == .position(1, of: 12))
    }

    @Test(arguments: [
        (nil, 3, nil, TerminalFindCount.empty),
        ("a", nil, nil, .empty),
        ("a", 0, nil, .noMatches),
        ("a", 3, nil, .empty),
        ("a", 3, 0, .position(1, of: 3)),
        ("a", 3, 2, .position(3, of: 3)),
    ] as [(String?, Int?, Int?, TerminalFindCount)])
    func countLabel(query: String?, total: Int?, selected: Int?, expected: TerminalFindCount) {
        #expect(TerminalFindCount(query: query ?? "", total: total, selected: selected) == expected)
    }

    // MARK: Next and previous

    @Test func nextAndPreviousWrapAtBothEnds() {
        let (find, stub) = makeFind(["warn": 3])
        find.open()
        type("warn", into: find, stub)
        #expect(find.count == .position(1, of: 3))

        find.navigate(.next)
        find.navigate(.next)
        stub.flush()
        #expect(find.count == .position(3, of: 3))

        find.navigate(.next)
        stub.flush()
        #expect(find.count == .position(1, of: 3))

        find.navigate(.previous)
        stub.flush()
        #expect(find.count == .position(3, of: 3))
    }

    @Test func navigatingWithoutAQueryIsRefused() {
        let (find, stub) = makeFind()
        #expect(find.navigate(.next) == false)
        #expect(stub.calls.isEmpty)
        #expect(!find.isPresented)
    }

    @Test func findNextAfterCloseReopensWithTheLastQuery() {
        let (find, stub) = makeFind()
        find.open()
        type("error", into: find, stub)
        find.close()
        stub.flush()

        #expect(find.navigate(.next))
        stub.flush()
        #expect(find.isPresented)
        #expect(stub.needle == "error")
        #expect(find.count == .position(1, of: 12))
    }

    // MARK: Reveal

    @Test func theFirstMatchIsSelectedSoTheTerminalScrollsToIt() {
        let (find, stub) = makeFind(["deploy": 4])
        // Every match is up in scrollback.
        stub.lastVisibleMatch = -1
        find.open()
        type("deploy", into: find, stub)

        #expect(stub.selectedMatch == 0)
        #expect(stub.scrolledToMatch == 0)
        #expect(find.count == .position(1, of: 4))
    }

    @Test func steppingRevealsAnOffScreenMatchInScrollback() {
        let (find, stub) = makeFind(["error": 12])
        stub.lastVisibleMatch = 2
        find.open()
        type("error", into: find, stub)
        for _ in 0..<9 { find.navigate(.next) }
        stub.flush()

        #expect(stub.scrolledToMatch == 9)
        #expect(find.count == .position(10, of: 12))
    }

    @Test func revealSelectsOnlyOnceWhileTotalsArriveInSteps() {
        let (find, stub) = makeFind(["error": 12])
        stub.partialTotals = [2, 7]
        find.open()
        type("error", into: find, stub)

        #expect(stub.calls.filter { $0 == .navigate(.next) }.count == 1)
        #expect(find.count == .position(1, of: 12))
    }

    // MARK: Open and close

    @Test func cmdFReopensWithTheLastQueryAndAsksForFocus() {
        let (find, stub) = makeFind()
        find.open()
        let firstRequest = find.focusRequest
        type("error", into: find, stub)
        find.close()
        stub.flush()

        find.open()
        stub.flush()
        #expect(find.isPresented)
        #expect(find.query == "error")
        #expect(find.focusRequest > firstRequest)
        #expect(stub.needle == "error")
        #expect(find.count == .position(1, of: 12))
    }

    @Test func openWithASeedSearchesForIt() {
        let (find, stub) = makeFind(["build": 2])
        find.open(seed: "build")
        stub.flush()
        #expect(find.query == "build")
        #expect(find.count == .position(1, of: 2))
    }

    @Test func escapeClosesClearsHighlightsAndSelectionAndFocusesTheTerminal() {
        let (find, stub) = makeFind()
        find.open()
        type("error", into: find, stub)
        find.navigate(.next)
        stub.flush()

        find.close()
        stub.flush()

        #expect(!find.isPresented)
        #expect(!stub.isSearching)
        #expect(stub.selectedMatch == nil)
        #expect(!stub.hasSelection)
        #expect(Array(stub.calls.suffix(3)) == [.endSearch, .clearSelection, .focusTerminal])
        #expect(find.count == .empty)
        #expect(find.query == "error")
    }

    @Test func ghosttyEndingTheSearchHidesTheBarWithoutMovingFocus() {
        let (find, stub) = makeFind()
        find.open()
        type("error", into: find, stub)
        find.searchEnded()

        #expect(!find.isPresented)
        #expect(find.count == .empty)
        #expect(!stub.calls.contains(.focusTerminal))
    }

    @Test func ghosttyStartingASearchOpensTheBar() {
        let (find, stub) = makeFind(["main": 5])
        find.searchStarted(needle: "main")
        stub.flush()
        #expect(find.isPresented)
        #expect(find.count == .position(1, of: 5))
    }

    // MARK: Keys

    @Test(arguments: [
        ("\r", TerminalFindKeyCommand.Modifiers(), TerminalFindKeyCommand.next),
        ("\r", .shift, .previous),
        ("g", .command, .next),
        ("G", [.command, .shift], .previous),
        ("g", [.command, .option], .previous),
        ("\u{1b}", [], .close),
    ] as [(String, TerminalFindKeyCommand.Modifiers, TerminalFindKeyCommand)])
    func barKeys(key: String, modifiers: TerminalFindKeyCommand.Modifiers, expected: TerminalFindKeyCommand) {
        #expect(TerminalFindKeyCommand(key: key, modifiers: modifiers) == expected)
    }

    @Test func otherKeysReachTheField() {
        #expect(TerminalFindKeyCommand(key: "g", modifiers: []) == nil)
        #expect(TerminalFindKeyCommand(key: "\r", modifiers: .command) == nil)
        #expect(TerminalFindKeyCommand(key: "f", modifiers: .command) == nil)
    }
}
