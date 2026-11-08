import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A tap on a web link in the terminal finds the whole URL, as the Mac's Cmd-click does
/// (`TerminalWrappedLink`): on its row, or across the rows a program broke it onto.
@Suite struct TerminalLinkFinderTests {
    @Test func aLinkOnOneRowIsFoundWhereverItIsTapped() {
        let finder = TerminalLinkFinder(rows: ["docs at https://cmux.com/docs/next, see"], firstRow: 40, columns: 80)
        for column in [8, 20, 33] {
            #expect(finder.link(row: 40, column: column)?.url.absoluteString == "https://cmux.com/docs/next")
        }
        // The comma after it, the words around it: no link.
        #expect(finder.link(row: 40, column: 34) == nil)
        #expect(finder.link(row: 40, column: 2) == nil)
    }

    @Test func aLinkTheProgramBrokeAtTheEdgeIsJoined() {
        // 20 columns: Claude Code broke the URL at the right edge.
        let rows = ["  ⎿ https://example",
                    ".com/a/b?x=1 done"]
        let finder = TerminalLinkFinder(rows: rows, firstRow: 0, columns: 19)
        let link = finder.link(row: 1, column: 3)
        #expect(link?.url.absoluteString == "https://example.com/a/b?x=1")
        #expect(link?.segments == [TerminalLink.Segment(row: 0, start: 4, end: 18), TerminalLink.Segment(row: 1, start: 0, end: 11)])
        #expect(finder.link(row: 0, column: 6)?.url.absoluteString == "https://example.com/a/b?x=1")
    }

    @Test func proseOnTheNextRowIsNotPartOfALinkThatEndsShortOfTheEdge() {
        let rows = ["open https://cmux.com now",
                    "and then more text"]
        let finder = TerminalLinkFinder(rows: rows, firstRow: 0, columns: 80)
        #expect(finder.link(row: 0, column: 10)?.url.absoluteString == "https://cmux.com")
        #expect(finder.link(row: 1, column: 1) == nil)
    }

    @Test func onlyWebLinksAndWideCharactersKeepTheirCells() {
        // A file URL or a bare host is not a web link; a wide character before a link
        // shifts its cells by two.
        #expect(TerminalLinkFinder(rows: ["file:///etc/passwd"], firstRow: 0, columns: 80).link(row: 0, column: 5) == nil)
        let finder = TerminalLinkFinder(rows: ["日本 http://a.io/x"], firstRow: 0, columns: 80)
        let link = finder.link(row: 0, column: 6)
        #expect(link?.url.absoluteString == "http://a.io/x")
        #expect(link?.segments == [TerminalLink.Segment(row: 0, start: 5, end: 17)])
        #expect(finder.link(row: 0, column: 1) == nil)
    }
}
