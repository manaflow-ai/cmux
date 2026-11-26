#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24, back from another app: "The like multi-second long reattach where like the
/// entire thing is somehow grayed out and I can't interact with anything at all." A restored
/// page is a live surface fed its kept rows before the attach, never a still picture.
@MainActor
struct TerminalSeedTests {
    @Test func keepsTheRowsWithoutTheBlankOnesAroundThem() {
        #expect(TerminalSeed.rows(fromScreenText: "\n\n$ ls\r\nfile\n$ \n\n  \n") == "$ ls\nfile\n$ ")
        #expect(TerminalSeed.rows(fromScreenText: "\n  \n\n") == nil)
        #expect(TerminalSeed.rows(fromScreenText: "") == nil)
    }

    @Test func keepsOnlyTheNewestRowsWithinTheBounds() throws {
        let many = (0..<(TerminalSeed.maxRows + 50)).map { "row \($0)" }.joined(separator: "\n")
        let rows = try #require(TerminalSeed.rows(fromScreenText: many)).split(separator: "\n")
        #expect(rows.count == TerminalSeed.maxRows)
        #expect(rows.last == "row \(TerminalSeed.maxRows + 49)")

        let wide = String(repeating: "x", count: 1_000)
        let big = (0..<400).map { "\($0) \(wide)" }.joined(separator: "\n")
        let kept = try #require(TerminalSeed.rows(fromScreenText: big))
        #expect(kept.utf8.count <= TerminalSeed.maxBytes)
        #expect(kept.hasSuffix("399 \(wide)"))
    }

    @Test func feedsOnlyPrintableTextOneRowPerLine() {
        let bytes = TerminalSeed.bytes(rows: "a\u{1B}]0;title\u{07}b\tc\nd\u{9B}2Je")
        #expect(String(decoding: bytes, as: UTF8.self) == "a]0;titleb\tc\r\nd2Je")
        #expect(TerminalSeed.bytes(rows: "é ✓") == Data("é ✓".utf8))
    }

    @Test func theSurfaceIsSeededOnceFromItsKeptRows() throws {
        let model = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: "t")
        model.cardScreenText = "the Mac's"
        model.restoreLastRows("$ make\nok")
        #expect(!model.seeded)
        #expect(try #require(model.takeSeed()) == Data("$ make\r\nok".utf8))
        #expect(model.seeded)
        #expect(model.takeSeed() == nil, "once: the Mac's replay replaces it")
        #expect(model.rowsToKeep() == "$ make\nok", "a host cooled before live output hands its rows on")
    }

    @Test func withNoKeptRowsTheMacsScreenTextSeedsIt() throws {
        let model = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: "t")
        #expect(model.takeSeed() == nil, "nothing to show: the cover's skeleton")
        let fresh = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: "t")
        fresh.cardScreenText = "$ top\n\n"
        #expect(try #require(fresh.takeSeed()) == Data("$ top".utf8))
    }

    /// Leo, 2026-11-25: "the layout calculations too". The Mac's screen text is its rows at the
    /// Mac pane's width (Claude Code's rules across 90 columns); fed to a 53-column surface each
    /// one wrapped onto a row and a half. Cut at the surface's columns, a Mac row is one row.
    @Test func theMacsScreenTextIsCutAtTheSurfacesColumnsNeverWrapped() throws {
        let rule = String(repeating: "\u{2500}", count: 90)
        let mac = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: "t")
        mac.cardScreenText = "\(rule)\n\u{276F} \n\(rule)\n  Opus 5.5 | ctx:186.4k/400k(47%) | ~$7304.91 API | 295h7m"
        let seeded = String(decoding: try #require(mac.takeSeed(columns: 53)), as: UTF8.self)
        let rows = seeded.components(separatedBy: "\r\n")
        #expect(rows.count == 4, "one phone row per Mac row: \(rows)")
        #expect(rows[0] == String(repeating: "\u{2500}", count: 53))
        #expect(rows[1] == "\u{276F} ")
        #expect(rows.allSatisfy { $0.count <= 53 })

        // The phone's own kept rows are its own width (and joined soft wraps): never cut.
        let own = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: "t")
        own.restoreLastRows(rule)
        #expect(String(decoding: try #require(own.takeSeed(columns: 53)), as: UTF8.self) == rule)
    }

    @Test func aCutCountsWideCharactersAsTwoColumns() {
        #expect(TerminalSeed.rows("日本語テキスト\nabcdef", clippedTo: 5) == "日本\nabcde")
        #expect(TerminalSeed.rows("a✓b", clippedTo: 2) == "a✓")
        #expect(TerminalSeed.rows("anything", clippedTo: 0) == "anything", "no grid measured: nothing cut")
    }

    @Test func aLiveOrSeededPageHasNothingOverIt() {
        // Seeded or drawn: the live surface, at full opacity, takes the touches.
        #expect(!TerminalTabPage.showsCover(attached: false, seeded: true, drewLiveOutput: false, heldFrame: true))
        #expect(!TerminalTabPage.showsCover(attached: false, seeded: false, drewLiveOutput: true, heldFrame: false))
        // Nothing of its own yet: the Mac's text or a skeleton until the live rows draw.
        #expect(TerminalTabPage.showsCover(attached: false, seeded: false, drewLiveOutput: false, heldFrame: false))
        #expect(TerminalTabPage.showsCover(attached: true, seeded: false, drewLiveOutput: false, heldFrame: true))
        #expect(!TerminalTabPage.showsCover(attached: true, seeded: false, drewLiveOutput: false, heldFrame: false))
    }
}
#endif
