import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite struct AlternateScreenDetectorTests {
    @Test func entersAndLeavesAcrossChunks() {
        var detector = AlternateScreenDetector()
        #expect(detector.scan(Data("hello \u{1B}[?10".utf8)) == nil)
        #expect(detector.scan(Data("49h\u{1B}[H".utf8)) == true)
        #expect(detector.isActive)
        #expect(detector.scan(Data("\u{1B}[?1049l".utf8)) == false)
    }

    @Test func ignoresOtherPrivateModes() {
        var detector = AlternateScreenDetector()
        #expect(detector.scan(Data("\u{1B}[?25l\u{1B}[?2004h".utf8)) == nil)
        #expect(!detector.isActive)
    }
}

@Suite struct ArtifactExtractorTests {
    @Test func findsPathsLinksAndDirectories() {
        var extractor = ArtifactExtractor()
        let text = """
        \u{1B}[1;32m   Compiling\u{1B}[0m serde v1.0.217 (crates.io)
          --> src/link/mux.rs:142:9
           Artifact target/release/cmux-mobile-host (8.4 MB)
           Report   docs/architecture.md, index.html
           PR https://github.com/manaflow-ai/cmux/pull/1234.
        drwxr-xr-x  aziz staff 4.0K Oct  9 18:22 screenshots
        finished in 48.21s, 2026/10/07

        """
        let found = extractor.scan(Data(text.utf8))
        let byReference = Dictionary(uniqueKeysWithValues: found.map { ($0.reference, $0) })
        #expect(byReference["src/link/mux.rs"]?.kind == .code)
        #expect(byReference["src/link/mux.rs"]?.line == 142)
        #expect(byReference["target/release/cmux-mobile-host"]?.kind == .binary)
        #expect(byReference["docs/architecture.md"]?.kind == .markdown)
        #expect(byReference["index.html"]?.kind == .html)
        #expect(byReference["https://github.com/manaflow-ai/cmux/pull/1234"]?.kind == .link)
        #expect(byReference["screenshots/"]?.kind == .directory)
        #expect(byReference["v1.0.217"] == nil)
        #expect(byReference["crates.io"] == nil)
        #expect(byReference["48.21s"] == nil)
        #expect(byReference["2026/10/07"] == nil)
    }

    @Test func reportsEachReferenceOnceAndKeepsPartialLines() {
        var extractor = ArtifactExtractor()
        #expect(extractor.scan(Data("see READ".utf8)).isEmpty)
        #expect(extractor.scan(Data("ME.md\n".utf8)).map(\.reference) == ["README.md"])
        #expect(extractor.scan(Data("README.md again\n".utf8)).isEmpty)
    }

    /// e2e-live.md: a path the Mac's grid wrapped arrived as two rows, and the
    /// stream scan listed `/live/work/demo/REA` and `DME.md`.
    @Test func wrappedPathInTheStreamIsTwoFragments() {
        var extractor = ArtifactExtractor()
        let found = extractor.scan(Data("cat /live/work/demo/REA\r\nDME.md\r\n".utf8))
        #expect(found.map(\.reference) == ["/live/work/demo/REA", "DME.md"])
    }

    @Test func rowsThatFillTheWidthJoinTheNextRow() {
        // 20 columns: the first row is full, so the next one continues it.
        let rows = "$ cat /live/work/dem\no/README.md\nshort line\n$ "
        #expect(ArtifactExtractor.logicalLines(in: rows, columns: 20)
            == ["$ cat /live/work/demo/README.md", "short line", "$ "])
        // Without a width, rows are lines as written.
        #expect(ArtifactExtractor.logicalLines(in: rows, columns: nil).count == 4)
        // A full row that ends in a space is a finished line.
        #expect(ArtifactExtractor.logicalLines(in: "abcdefghi \nnext", columns: 10) == ["abcdefghi ", "next"])
        // A full-width rule is a line of its own, so the path after it keeps its start.
        #expect(ArtifactExtractor.logicalLines(in: "----------\n/etc/hosts", columns: 10) == ["----------", "/etc/hosts"])
    }

    @Test func screenTextReplacesWrappedFragments() {
        var extractor = ArtifactExtractor()
        var artifacts = extractor.scan(Data("open docs/a.md\r\ncat /live/work/demo/REA\r\nDME.md\r\nhttps://example.com/lo\r\nng/page\r\n".utf8))
        #expect(artifacts.map(\.reference).contains("/live/work/demo/REA"))
        // Ghostty's screen read joins soft-wrapped rows into one logical line.
        let screen = "open docs/a.md\ncat /live/work/demo/README.md\nhttps://example.com/long/page\n"
        artifacts = extractor.reconcile(artifacts, screenText: screen, columns: nil)
        #expect(artifacts.map(\.reference) == ["docs/a.md", "/live/work/demo/README.md", "https://example.com/long/page"])
        // The whole reference takes its first fragment's place.
        #expect(artifacts.map(\.order) == artifacts.map(\.order).sorted())
        // Later output does not list it again.
        #expect(extractor.scan(Data("ls /live/work/demo/README.md\n".utf8)).isEmpty)
    }

    /// Seen live (round2.md): a command over three rows left its middle row,
    /// `e/r2/live/.../2026-10-13-round2-verifica`, as a folder.
    @Test func aMiddlePieceIsReplacedToo() {
        var extractor = ArtifactExtractor()
        let stream = "ls /Users/cmux/cmux-next-ios-e2\r\ne/r2/live/work/demo/reports/2026-10-13-round2-verifica\r\ntion/long-folder/x.md\r\n"
        var artifacts = extractor.scan(Data(stream.utf8))
        #expect(artifacts.count == 3)
        artifacts = extractor.reconcile(artifacts, screenText: "ls /Users/cmux/cmux-next-ios-e2e/r2/live/work/demo/reports/2026-10-13-round2-verification/long-folder/x.md\n", columns: nil)
        #expect(artifacts.map(\.reference) == ["/Users/cmux/cmux-next-ios-e2e/r2/live/work/demo/reports/2026-10-13-round2-verification/long-folder/x.md"])
    }

    /// R2-7 (seen live): the command line listed the whole path first, then
    /// `ls -l` output wrapped it at 53 columns; the piece `p/cmux-mobile-...md` stayed.
    @Test func aPieceOfAPathAlreadyListedWholeGoes() {
        var extractor = ArtifactExtractor()
        let stream = "clear; ls -l /tmp/cmux-mobile-e2e-070024-sample.md\r\n-rw-r--r--@ 1 aziz  wheel  40 Oct 14 07:00 /tm\r\np/cmux-mobile-e2e-070024-sample.md\r\n"
        var artifacts = extractor.scan(Data(stream.utf8))
        #expect(artifacts.map(\.reference).contains("p/cmux-mobile-e2e-070024-sample.md"))
        let screen = "clear; ls -l /tmp/cmux-mobile-e2e-070024-sample.md\n-rw-r--r--@ 1 aziz  wheel  40 Oct 14 07:00 /tmp/cmux-mobile-e2e-070024-sample.md\n"
        artifacts = extractor.reconcile(artifacts, screenText: screen, columns: nil)
        #expect(artifacts.map(\.reference) == ["/tmp/cmux-mobile-e2e-070024-sample.md"])
    }

    /// R3-3 (seen live): pieces of wrapped paths in scrollback, after the
    /// whole path left the screen.
    @Test func fragmentsInScrollbackGo() {
        let list = [
            TerminalArtifact(reference: "/tmp/cmux-mobile-e2e-091910.txt", kind: .text),
            TerminalArtifact(reference: "rivate/tmp/cmux-mobile-e2e-091910.txt", kind: .text),
            TerminalArtifact(reference: "1910.txt", kind: .text),
            TerminalArtifact(reference: "/tm", kind: .directory),
            TerminalArtifact(reference: "docs/a.md", kind: .markdown),
            TerminalArtifact(reference: "/repo/docs/a.md", kind: .markdown),
            TerminalArtifact(reference: "https://cmux.com/a", kind: .link),
        ]
        #expect(ArtifactExtractor.droppingFragments(list).map(\.reference)
                == ["/tmp/cmux-mobile-e2e-091910.txt", "docs/a.md", "/repo/docs/a.md", "https://cmux.com/a"])
    }

    @Test func tmpAndPrivateTmpAreOneEntry() {
        var extractor = ArtifactExtractor()
        let artifacts = extractor.scan(Data("cat /tmp/x.md\nopen /private/tmp/x.md\n".utf8))
        #expect(artifacts.map(\.reference) == ["/tmp/x.md"])
        #expect(ArtifactExtractor.canonical("/private/var/log/a.txt") == "/var/log/a.txt")
        let merged = extractor.reconcile(artifacts, screenText: "open /private/tmp/x.md\n", columns: nil)
        #expect(merged.map(\.reference) == ["/tmp/x.md"])
    }

    @Test func reconcileKeepsHistoryThatLeftTheScreen() {
        var extractor = ArtifactExtractor()
        let artifacts = extractor.scan(Data("old/notes.md\n".utf8))
        let merged = extractor.reconcile(artifacts, screenText: "new/plan.md\n", columns: nil)
        #expect(merged.map(\.reference) == ["old/notes.md", "new/plan.md"])
    }
}

#if os(iOS)
@MainActor @Suite struct TerminalScreenLogicTests {
    @Test func joystickGears() {
        #expect(JoystickEngine.gear(for: 4) == 0)
        #expect(JoystickEngine.gear(for: 10) == 1)
        #expect(JoystickEngine.gear(for: 20) == 2)
        #expect(JoystickEngine.gear(for: 30) == 3)
        #expect(JoystickEngine.direction(for: CGSize(width: -12, height: 3)) == .left)
        #expect(JoystickEngine.direction(for: CGSize(width: 2, height: 15)) == .down)
    }

    @Test func frameMatchingPrefersTheExpectedShift() {
        let previous: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 0]
        let moved: [UInt64] = [3, 4, 5, 6, 7, 0, 0, 0, 0, 0]
        #expect(TerminalPresentMatch.score(previous, moved, shift: 3) == 1)
        #expect(TerminalPresentMatch.score(previous, moved, shift: 0) == 0)
    }
}
#endif

/// The Mac's 42-row screen on the bottom of a 151-row mirror (offset 109).
@Suite struct TerminalRowShiftTests {
    /// User report (2026-10-14): Codex CLI prints its history with a scroll
    /// region from the screen's top (`ESC[1;Nr` then `\r\n` per line). On the
    /// Mac those lines go to the scrollback; shifted, the region started
    /// below the mirror's top and every line was discarded. The region keeps
    /// the mirror's first row as its top.
    @Test func aRegionFromTheTopKeepsTheMirrorsTop() {
        var shift = TerminalRowShift()
        let out = String(decoding: shift.filter(Data("\u{1B}[1;30r".utf8), offset: 109, remoteRows: 42), as: UTF8.self)
        #expect(out == "\u{1B}[1;139r")
        // A region below the top is still shifted whole.
        #expect(String(decoding: shift.filter(Data("\u{1B}[31;42r".utf8), offset: 109, remoteRows: 42), as: UTF8.self) == "\u{1B}[140;151r")
    }

    private func run(_ chunks: [String], offset: Int = 109, rows: Int = 42) -> String {
        var shift = TerminalRowShift()
        return chunks.map { String(decoding: shift.filter(Data($0.utf8), offset: offset, remoteRows: rows), as: UTF8.self) }.joined()
    }

    @Test func replayLandsOnTheBottomRows() {
        // The daemon's replay: reset, history, then the cursor on its row 42.
        let out = run(["\u{1B}c", "1\r\n2\r\n$ ", "\u{1B}[42;30H"])
        #expect(out == "\u{1B}c" + String(repeating: "\n", count: 109) + "1\r\n2\r\n$ \u{1B}[151;30H")
    }

    /// The Mac's Clear Screen and Scrollback (`clear-history`) ends in `ESC[3J`: the rows
    /// above the Mac's screen are history on the Mac, screen rows on the phone, and go too.
    @Test func eraseSavedLinesAlsoErasesTheRowsAboveTheMacsScreen() {
        #expect(run(["\u{1B}[3", "J"]) == "\u{1B}[3J\u{1B}7\u{1B}[109;9999H\u{1B}[1J\u{1B}8")
        // Other erases, and no offset, pass through.
        #expect(run(["\u{1B}[2J\u{1B}[J"]) == "\u{1B}[2J\u{1B}[J")
        #expect(run(["\u{1B}[3J"], offset: 0) == "\u{1B}[3J")
    }

    @Test func rowAddressingShiftsAcrossChunks() {
        #expect(run(["\u{1B}[", "5;", "1H x \u{1B}[H \u{1B}[3d"]) == "\u{1B}[114;1H x \u{1B}[110;1H \u{1B}[112d")
        // Column-only and relative moves are untouched.
        #expect(run(["\u{1B}[5G\u{1B}[2A\u{1B}[K"]) == "\u{1B}[5G\u{1B}[2A\u{1B}[K")
    }

    /// Entering the alternate screen moves the copied cursor up to the Mac's
    /// row (margins reset first so nothing stops it), then limits the scroll
    /// margins to the Mac's rows (the alternate screen is drawn from the
    /// mirror's top).
    private let toTUIRows = "\u{1B}7\u{1B}[r\u{1B}8\u{1B}[109A"
    private let tuiMargins = "\u{1B}7\u{1B}[1;42r\u{1B}8"
    private var altEnter: String { "\u{1B}[?1049h" + toTUIRows + tuiMargins }

    /// User report 2026-10-21 (Claude Code over 5G): the attach replay of a TUI
    /// draws its rows from the cursor, so the copied cursor must be on the Mac's
    /// row in the alternate screen; 47/1047 copy it back on the way out.
    @Test func theCopiedCursorMovesBetweenTheMirrorsRowNumberings() {
        #expect(run(["\u{1B}[?1047h", "\u{1B}[?1047l"]) == "\u{1B}[?1047h" + toTUIRows + tuiMargins + "\u{1B}[?1047l\u{1B}7\u{1B}[r\u{1B}8\u{1B}[109B")
        // 1049 restores the cursor it saved on the primary screen: no move.
        #expect(run(["\u{1B}[?1049h", "\u{1B}[?1049l"]) == altEnter + "\u{1B}[?1049l\u{1B}7\u{1B}[r\u{1B}8")
        // Leaving while not on the alternate screen: no move.
        #expect(run(["\u{1B}[?1047l"]) == "\u{1B}[?1047l\u{1B}7\u{1B}[r\u{1B}8")
        // A mix that includes 1049 restores the saved cursor: no move.
        #expect(run(["\u{1B}[?1049h", "\u{1B}[?1047;1049l"]) == altEnter + "\u{1B}[?1047;1049l\u{1B}7\u{1B}[r\u{1B}8")
        // 47 leaving after a 1049 entry copies the cursor back: moved down.
        #expect(run(["\u{1B}[?1049h", "\u{1B}[?47l"]) == altEnter + "\u{1B}[?47l\u{1B}7\u{1B}[r\u{1B}8\u{1B}[109B")
        // A reset puts the mirror back on the primary screen.
        #expect(run(["\u{1B}[?1049h", "\u{1B}c", "\u{1B}[?1049h"]).hasSuffix(altEnter))
    }

    @Test func alternateScreenIsNotShifted() {
        let out = run(["\u{1B}[?1049h\u{1B}[1;1Hvim\u{1B}[42;1H", "\u{1B}[?1049l\u{1B}[42;1H"])
        #expect(out == altEnter + "\u{1B}[1;1Hvim\u{1B}[42;1H\u{1B}[?1049l\u{1B}7\u{1B}[r\u{1B}8\u{1B}[151;1H")
        // vim's region for its 42 rows stays as is on the alternate screen; leaving resets it.
        #expect(run(["\u{1B}[?1049h\u{1B}[1;42r", "\u{1B}[?1049l"]) == altEnter + "\u{1B}[1;42r\u{1B}[?1049l\u{1B}7\u{1B}[r\u{1B}8")
    }

    /// Live check (2026-10-21): `less` scrolls with a line feed on its last
    /// row and sets no margins. On the 151-row mirror that line feed moved
    /// the cursor below the Mac's 42 rows instead of scrolling, so the phone
    /// kept showing the first page while the Mac's less moved on. The
    /// alternate screen's margins are the Mac's rows, and a reset of the
    /// margins there goes back to them.
    @Test func theAlternateScreenScrollsAtTheMacsLastRow() {
        #expect(run(["\u{1B}[?1049h"]) == altEnter)
        #expect(run(["\u{1B}[?1049h", "\u{1B}[r", "\u{1B}[1;42r", "\u{1B}[3;10r"])
            == altEnter + "\u{1B}[1;42r\u{1B}[1;42r\u{1B}[3;10r")
        // Every reset form is the Mac's screen; a bottom past it is clamped.
        #expect(run(["\u{1B}[?1049h", "\u{1B}[;r\u{1B}[0;0r\u{1B}[1;0r\u{1B}[5r\u{1B}[2;99r"])
            == altEnter + "\u{1B}[1;42r\u{1B}[1;42r\u{1B}[1;42r\u{1B}[5;42r\u{1B}[2;42r")
        // Mode 47 and 1047 too; with no mirror offset, nothing is added.
        #expect(run(["\u{1B}[?47h"]) == "\u{1B}[?47h" + toTUIRows + tuiMargins)
        #expect(run(["\u{1B}[?1049h\u{1B}[r"], offset: 0) == "\u{1B}[?1049h\u{1B}[r")
        // Already on the alternate screen (a repeated switch): set again, harmless.
        #expect(run(["\u{1B}[?1049h", "\u{1B}[?1049h"]) == altEnter + "\u{1B}[?1049h" + tuiMargins)
    }

    @Test func fullScreenRegionKeepsTheScrollback() {
        #expect(run(["\u{1B}[1;42r"]) == "\u{1B}[r")
        #expect(run(["\u{1B}[r"]) == "\u{1B}[r")
        #expect(run(["\u{1B}[2;10r"]) == "\u{1B}[111;119r")
    }

    @Test func stringsPassThrough() {
        let osc = "\u{1B}]7;file://host/Users/x[1;1H\u{07}\u{1B}]2;t\u{1B}\\\u{1B}[1;1H"
        #expect(run([osc]) == "\u{1B}]7;file://host/Users/x[1;1H\u{07}\u{1B}]2;t\u{1B}\\\u{1B}[110;1H")
        #expect(run(["\u{1B}[1;1H"], offset: 0) == "\u{1B}[1;1H")
        #expect(run(["\u{1B}(B\u{1B}[?25l"]) == "\u{1B}(B\u{1B}[?25l")
    }
}

/// termqa V2-2/D7: while following a stream, about 9 times a minute the page
/// showed one frame one row low with the newest row gone, then moved back up
/// (VERIFY-round2 frames 16.483/16.522/16.550 s). Shape: the frame on screen
/// is at viewport T (the newest row visible); Ghostty then presents a frame it
/// rendered for viewport T-1 (before the last row arrived). Ghostty follows
/// the output on its own, so no request names T-1 and it was not a candidate:
/// nothing matched, and the fallback placed the old picture at T, one row low.
/// The frame must be placed at T-1, where its rows belong (no visible move).
@Suite struct TerminalPresentMatchTests {
    /// Signatures of a viewport `top` of `count` rows of numbered stream rows.
    func rows(top: Int, count: Int = 120) -> [UInt64] { (top..<(top + count)).map { UInt64(1000 + $0) } }

    /// termqa round 7 (following cost): following still read all 151 rows of
    /// every frame (p99 3.36 ms). Only the rows on screen and a margin are
    /// read; the rows outside the band are `unread` and never compared.
    func banded(_ rows: [UInt64], _ band: Range<Int>) -> [UInt64] {
        rows.indices.map { band.contains($0) ? rows[$0] : TerminalPresentMatch.unread }
    }

    @Test func bandLimitedFramesMatchFollowingShifts() {
        let t = 900
        let band = TerminalPresentMatch.readBand(visible: 54..<96, rowCount: 120, margin: 16)
        #expect(band == 38..<112)
        for (current, reported) in [(t + 3, t + 3), (t - 1, t), (t + 1, t + 1), (t, t)] {
            let match = TerminalPresentMatch(presentedTop: t, reportedTop: reported, requestedTop: 780, recentRequests: [],
                                             activeTop: reported)
            let result = match.match(previous: banded(rows(top: t), band), current: banded(rows(top: current), band))
            #expect(result.top == current)
            #expect(result.matched)
        }
    }

    @Test func unreadRowsAreNeverCountedAsBlankOrEqual() {
        let band = 50..<60
        let previous = banded(rows(top: 0), band)
        // Everything outside the band is `unread` in both: only the band counts.
        #expect(TerminalPresentMatch.score(previous, banded(rows(top: 0), band), shift: 0) == 1)
        #expect(TerminalPresentMatch.score(previous, banded(rows(top: 40), band), shift: 0) == 0)
        #expect(TerminalPresentMatch.readBand(visible: 0..<10, rowCount: 20, margin: 16) == 0..<20)
    }

    /// VERIFY-round6 V6-2: following at the history cap, Ghostty pruned 886
    /// rows (17740 -> 16854). The viewport followed the output, so no prune
    /// was detected and the frame on screen kept its top in the old numbering
    /// (17589). The next frame (one new row) matched shift +1 and was placed
    /// at 17590, past the document's end: a black page until the next touch.
    /// A frame's top is never past the active area's top.
    @Test func aFrameIsNeverPlacedPastTheActiveTop() {
        let stale = 17589
        let match = TerminalPresentMatch(presentedTop: stale, reportedTop: 16703, requestedTop: stale, recentRequests: [],
                                         activeTop: 16703)
        let result = match.match(previous: rows(top: 0), current: rows(top: 1))
        #expect(result.top == 16703)
        #expect(result.top <= match.activeTop)
        // Any candidate past the active top is out, even a perfect one.
        let same = match.match(previous: rows(top: 0), current: rows(top: 0))
        #expect(same.top == 16703)
    }

    @Test func aStaleFrameOneRowOlderStaysWhereItsRowsBelong() {
        let t = 900
        let match = TerminalPresentMatch(presentedTop: t, reportedTop: t, requestedTop: 780, recentRequests: [700, 740],
                                         activeTop: t)
        #expect(match.top(previous: rows(top: t), current: rows(top: t - 1)) == t - 1)
        #expect(match.top(previous: rows(top: t), current: rows(top: t - 2)) == t - 2)
    }

    @Test func theNewerFrameStillMovesUp() {
        let t = 900
        let match = TerminalPresentMatch(presentedTop: t, reportedTop: t + 1, requestedTop: 780, recentRequests: [], activeTop: t + 1)
        #expect(match.top(previous: rows(top: t), current: rows(top: t + 1)) == t + 1)
        // The same picture again: no move.
        #expect(match.top(previous: rows(top: t), current: rows(top: t)) == t)
    }
    /// termqa round 6 (scroll while streaming): every present read the
    /// frame's pixels on the main thread (about 1 ms a frame). While the page
    /// reads scrollback, Ghostty does not move the viewport on its own, so once
    /// a read frame confirmed the requested and reported viewport, the frames
    /// after it show that viewport until a request, a report or the surface
    /// (epoch) moves it: they are placed without a read.
    @Test func aConfirmedViewportInScrollbackPlacesFramesWithoutAPixelRead() {
        let match = TerminalPresentMatch(presentedTop: 400, reportedTop: 400, requestedTop: 400, recentRequests: [360],
                                         activeTop: 900)
        let result = match.match(previous: rows(top: 400), current: rows(top: 400))
        #expect(result.top == 400)
        #expect(result.matched)
        let steady = match.confirmed(result, epoch: 7)
        #expect(steady == TerminalSteadyViewport(top: 400, epoch: 7))
        #expect(match.knownTop(steady: steady, epoch: 7) == 400)
        // The surface moved its viewport (a request, a resize, a font change).
        #expect(match.knownTop(steady: steady, epoch: 8) == nil)
        // A report or a request for another viewport.
        var moved = match
        moved.reportedTop = 380
        #expect(moved.knownTop(steady: steady, epoch: 7) == nil)
        moved = match
        moved.requestedTop = 420
        #expect(moved.knownTop(steady: steady, epoch: 7) == nil)
    }

    /// Following (the viewport in the active area), Ghostty moves the
    /// viewport with the output and stale frames arrive (D7): always read.
    @Test func followingAlwaysReadsThePixels() {
        let match = TerminalPresentMatch(presentedTop: 900, reportedTop: 900, requestedTop: 900, recentRequests: [],
                                         activeTop: 900)
        let result = match.match(previous: rows(top: 900), current: rows(top: 900))
        #expect(match.confirmed(result, epoch: 1) == nil)
        #expect(match.knownTop(steady: TerminalSteadyViewport(top: 900, epoch: 1), epoch: 1) == nil)
    }

    /// A frame placed by the fallback (no candidate matched) confirms nothing.
    @Test func aFallbackPlacementConfirmsNothing() {
        let match = TerminalPresentMatch(presentedTop: 400, reportedTop: 400, requestedTop: 400, recentRequests: [],
                                         activeTop: 900)
        let unrelated = (0..<120).map { UInt64(77_000 + $0 * 13) }
        let result = match.match(previous: rows(top: 400), current: unrelated)
        #expect(!result.matched)
        #expect(result.top == 400)
        #expect(match.confirmed(result, epoch: 1) == nil)
    }
}
