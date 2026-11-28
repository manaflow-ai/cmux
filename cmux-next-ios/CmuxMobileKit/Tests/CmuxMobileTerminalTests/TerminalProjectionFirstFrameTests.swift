// The projection (TerminalProjectingSession) and its FFI are iOS only, so the
// tests run on the kit job's iOS simulator leg, not under macOS swift test.
#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-23: "im sometimes seeing these 118x69 load ins which are
/// wide... then it properly goes."
///
/// Under the projection (the default) the phone claims no size on the
/// primary screen, so it attaches at the Mac pane's own grid. A terminal that
/// is in a full-screen app (the alternate screen) at load replays at that
/// grid (118x69 here); the page then claims the phone's grid and the Mac
/// answers with it. The page drew the Mac's 118 columns first, then the
/// phone's. The first frame of a full-screen app is now the phone's grid: the
/// Mac's waits until the claim is answered, and shows only if the Mac keeps
/// its grid past the wait.
@MainActor
@Suite struct TerminalProjectionFirstFrameTests {
    /// A Mac pane at 118x69 with a full-screen app on screen. It answers a
    /// claim when the test says so (a link round trip later).
    @MainActor final class MacTUIPane: TerminalSession {
        private(set) var grid = (columns: 118, rows: 69)
        private(set) var asked: (columns: Int, rows: Int)?
        private(set) var claims = false
        private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        var programName: String { "htop" }
        var isAlternateScreen: Bool { true }
        var remoteRows: Int? { grid.rows }
        var remoteColumns: Int? { grid.columns }

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
            self.handler = handler
            replay()
        }

        /// The claim arrives on the Mac: its PTY takes the phone's grid and replays.
        func answerClaim() {
            guard claims, let asked else { return }
            grid = asked
            replay()
        }

        private func replay() {
            handler?(.hostGrid(columns: grid.columns, rows: grid.rows))
            handler?(.output(TerminalReclaimHold.reset))
            handler?(.output(Data("\u{1B}[?1049h\u{1B}[HTUI at \(grid.columns)x\(grid.rows)".utf8)))
        }

        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) { asked = (columns, rows) }
        func setClaimsSize(_ claims: Bool) { self.claims = claims }
        func stop() { handler = nil }
    }

    /// What the page was told: every grid, in order, and the text drawn.
    @MainActor final class Page {
        var grids: [String] = []
        var text = ""
        func take(_ event: TerminalSessionEvent) {
            switch event {
            case .hostGrid(let columns, let rows): grids.append("\(columns)x\(rows)")
            case .output(let data): text += String(decoding: data, as: UTF8.self)
            default: break
            }
        }
    }

    /// Leo, 2026-11-25: "why would the Mac on an iPhone connection ALWAYS be
    /// resized down anyways!?" A full-screen app shows at the Mac's grid
    /// (scaled by the page) from its first frame: no claim, so no grid that
    /// flips once a claim is answered.
    @Test func aFullScreenAppShowsAtTheMacsGridAndNeverClaims() {
        let mac = MacTUIPane()
        let session = TerminalProjectingSession(inner: mac)
        let page = Page()
        session.resize(columns: 54, rows: 38)
        session.setClaimsSize(true)
        session.start { page.take($0) }
        #expect(!mac.claims, "the phone never claims its grid while it projects")
        #expect(page.grids.last == "118x69")
        #expect(page.text.contains("TUI at 118x69"))
        #expect(session.remoteColumns == 118)
        session.stop()
    }

    /// A Mac pane at 118x69 on the primary screen (a shell, Claude Code's
    /// inline box) that replays as soon as it attaches.
    @MainActor final class MacShellPane: TerminalSession {
        private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var resizes = 0
        var programName: String { "zsh" }
        var isAlternateScreen: Bool { false }
        var remoteRows: Int? { 69 }
        var remoteColumns: Int? { 118 }

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
            self.handler = handler
            handler(.hostGrid(columns: 118, rows: 69))
            handler(.output(TerminalReclaimHold.reset))
            handler(.output(Data("$ ls\r\nREADME.md\r\n$ ".utf8)))
        }

        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) { resizes += 1 }
        func stop() { handler = nil }
    }

    /// Leo, 2026-11-23: "im sometimes seeing these 118x69 load ins which are
    /// wide... then it properly goes." The Mac's replay can reach the page
    /// before the phone has measured its grid; the page is never told the
    /// Mac's 118x69 on the primary screen. Its first grid is the phone's own.
    @Test func thePrimaryScreensFirstGridIsThePhonesNeverTheMacs() {
        let mac = MacShellPane()
        let session = TerminalProjectingSession(inner: mac)
        let page = Page()
        // The replay comes first: the page has not measured yet.
        session.start { page.take($0) }
        #expect(!page.grids.contains("118x69"), "the Mac's grid reached a phone-width page: \(page.grids)")
        #expect(page.grids.isEmpty, "no grid before the phone measures: \(page.grids)")
        #expect(session.remoteColumns == nil, "the mirror keeps the page's own width until measured")
        // The phone measures its page (an iPhone 16 Pro, portrait).
        session.resize(columns: 43, rows: 33)
        #expect(page.grids.first == "43x33", "the first grid shown is the phone's: \(page.grids)")
        #expect(!page.grids.contains("118x69"))
        #expect(mac.resizes == 0, "the Mac keeps its grid")
        session.stop()
    }

    /// Measured before the start (the usual order): the first grid is the
    /// phone's, and the Mac's never follows on the primary screen.
    @Test func measuredBeforeTheStartTheFirstGridIsThePhones() {
        let mac = MacShellPane()
        let session = TerminalProjectingSession(inner: mac)
        let page = Page()
        session.resize(columns: 43, rows: 33)
        session.start { page.take($0) }
        #expect(page.grids == ["43x33"], "\(page.grids)")
        #expect(mac.resizes == 0)
        session.stop()
    }
}
#endif
