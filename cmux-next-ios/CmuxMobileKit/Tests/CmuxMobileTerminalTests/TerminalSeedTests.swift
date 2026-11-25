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
