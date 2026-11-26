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

    @Test func aFullScreenAppsFirstFrameIsThePhonesGrid() async throws {
        let mac = MacTUIPane()
        let session = TerminalProjectingSession(inner: mac)
        let page = Page()
        // The page measures its grid before the session starts (viewDidLayoutSubviews).
        session.resize(columns: 54, rows: 38)
        session.setClaimsSize(true)
        session.start { page.take($0) }
        #expect(mac.claims, "the full-screen app claims the phone's grid at once")
        #expect(!page.grids.contains("118x69"), "the Mac's 118x69 is never the first frame")
        #expect(!page.text.contains("TUI at 118x69"))
        #expect(session.remoteColumns != 118, "the page never lays its mirror out at the Mac's 118 columns")
        mac.answerClaim()
        #expect(!page.grids.contains("118x69"))
        #expect(page.grids.last == "54x38")
        #expect(page.text.contains("TUI at 54x38"))
        #expect(session.remoteColumns == 54)
        session.stop()
    }

    /// The Mac's policy keeps its own grid (Prefer this Mac): the claim is
    /// never answered, and the Mac's grid shows after the wait.
    @Test func aGridTheMacKeepsShowsAfterTheWait() async throws {
        let mac = MacTUIPane()
        let session = TerminalProjectingSession(inner: mac)
        session.reclaimWait = .milliseconds(20)
        let page = Page()
        session.resize(columns: 54, rows: 38)
        session.setClaimsSize(true)
        session.start { page.take($0) }
        #expect(!page.grids.contains("118x69"))
        for _ in 0..<300 where !page.grids.contains("118x69") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(page.grids.last == "118x69")
        #expect(page.text.contains("TUI at 118x69"))
        #expect(session.remoteColumns == 118)
        session.stop()
    }
}
#endif
