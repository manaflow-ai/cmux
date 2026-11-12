import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-12: "i swipe up into another app and it resize back... then
/// i go to it again and it resize again... surely this calculation of sort is
/// doable on the phone itself?" A hidden terminal releases the phone's size,
/// so the Mac's PTY goes back to the Mac's grid and replays it; coming back
/// claims the phone's grid and the Mac replays again. The page showed the
/// Mac's wide grid in between ("uncompact then squish"). The phone knows its
/// own grid: it holds the Mac's other grid while hidden and shows it only if
/// the claim does not bring its own grid back (`TerminalReclaimHold`).
@MainActor @Suite struct DaemonTerminalReclaimHoldTests {
    private static let wide = Data("wide-rows".utf8)
    private static let narrow = Data("narrow-rows".utf8)
    private static let reset = Data("\u{1B}c".utf8)

    private func grid(_ event: String, _ columns: Int, _ rows: Int, _ data: Data) -> Data {
        FakeTerminalDaemon.line(["event": event, "surface": 7, "cols": columns, "rows": rows,
                                 event == "resized" ? "replay" : "data": data.base64EncodedString()])
    }

    /// A session showing the phone's 50x20 grid.
    private func shownAtPhoneGrid() -> (DaemonTerminalSession, Box) {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        let box = Box()
        session.start { box.events.append($0) }
        session.resize(columns: 50, rows: 20)
        session.handle(grid("vt-state", 50, 20, Data("screen".utf8)))
        box.events.removeAll()
        return (session, box)
    }

    final class Box { var events: [TerminalSessionEvent] = [] }

    @Test func hiddenAndShownAgainNeverShowsTheMacsGrid() {
        let (session, box) = shownAtPhoneGrid()
        session.setClaimsSize(false)
        // The release: the Mac's pane takes its own grid back and replays it.
        session.handle(grid("resized", 120, 40, Self.wide))
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("more".utf8).base64EncodedString()]))
        #expect(!box.events.contains(.hostGrid(columns: 120, rows: 40)), "the hidden page never takes the Mac's grid")
        #expect(!box.events.contains(.output(Self.wide)))
        // Shown again: the claim brings the phone's grid back.
        session.setClaimsSize(true)
        session.handle(grid("resized", 50, 20, Self.narrow))
        #expect(!box.events.contains(.hostGrid(columns: 120, rows: 40)))
        #expect(!box.events.contains(.output(Self.wide)), "the replay for the Mac's grid is superseded, never drawn")
        #expect(!box.events.contains(.output(Data("more".utf8))))
        #expect(box.events.contains(.output(Self.reset)), "the phone's replay starts from a reset")
        #expect(box.events.last == .output(Self.narrow))
    }

    @Test func aClaimTheMacOverrulesShowsTheHeldGridInOrder() {
        let (session, box) = shownAtPhoneGrid()
        session.setClaimsSize(false)
        session.handle(grid("resized", 120, 40, Self.wide))
        #expect(box.events.isEmpty)
        // Still hidden, the stream ends (the Mac closed the terminal): what
        // was held is shown, in order, before the end.
        session.handle(FakeTerminalDaemon.line(["event": "detached", "surface": 7, "reason": "closed"]))
        let grid = box.events.firstIndex(of: .hostGrid(columns: 120, rows: 40))
        let wide = box.events.firstIndex(of: .output(Self.wide))
        let exited = box.events.firstIndex(of: .exited(code: 0))
        #expect(grid != nil && wide != nil && exited != nil)
        #expect(grid! < wide! && wide! < exited!)
    }

    @Test func aHiddenTUIThatQuitIsAShellWhenShownAgain() {
        let (session, box) = shownAtPhoneGrid()
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        #expect(box.events.last == .alternateScreen(true))
        box.events.removeAll()
        session.setClaimsSize(false)
        session.handle(grid("resized", 120, 40, Data("\u{1B}[?1049hvim".utf8)))
        // The program quits while the page is hidden.
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049l$ ".utf8).base64EncodedString()]))
        #expect(!session.isAlternateScreen)
        session.setClaimsSize(true)
        session.handle(grid("resized", 50, 20, Data("$ ".utf8)))
        #expect(box.events.contains(.alternateScreen(false)), "the screen leaves TUI mode before the phone's replay")
        let left = box.events.firstIndex(of: .alternateScreen(false))
        let reset = box.events.firstIndex(of: .output(Self.reset))
        #expect(left != nil && reset != nil && left! < reset!)
        #expect(box.events.last == .output(Data("$ ".utf8)))
    }

    @Test func shownAgainAtTheGridTheMacAlreadyHasShowsTheHeldBytes() {
        let (session, box) = shownAtPhoneGrid()
        session.setClaimsSize(false)
        session.handle(grid("resized", 120, 40, Self.wide))
        // The Mac came back to the phone's grid on its own while hidden.
        session.handle(grid("resized", 50, 20, Self.narrow))
        #expect(box.events.isEmpty)
        // No resize will come for the claim: what was held shows at once.
        session.setClaimsSize(true)
        #expect(box.events.last == .output(Self.narrow))
    }

    @Test func aPageThatIsShownNeverHoldsTheMacsGrid() {
        let (session, box) = shownAtPhoneGrid()
        // Another device sets a wider grid while this page is on screen:
        // the page shows it (PROTOCOL.md "A grid larger than the phone").
        session.handle(grid("resized", 120, 40, Self.wide))
        #expect(box.events.contains(.hostGrid(columns: 120, rows: 40)))
        #expect(box.events.last == .output(Self.wide))
    }
}
