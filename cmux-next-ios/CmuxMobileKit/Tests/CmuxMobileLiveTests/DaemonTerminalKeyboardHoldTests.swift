import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The keyboard hold (`TerminalKeyboardReplayHold`) driven by the real
/// session's events, in their order: the Mac's `resized` reaches the screen
/// as the grid, then the mirror reset, then the replay, each its own event;
/// a disconnect or a TUI leaving its screen in the middle ends the hold.
@MainActor @Suite struct DaemonTerminalKeyboardHoldTests {
    /// What the page does with each event (TerminalViewController's rules):
    /// the hold first, then the output queue, fed until it holds.
    private struct Page {
        var hold = TerminalKeyboardReplayHold()
        var queue = TerminalOutputQueue()
        var heldRows: Int? = 40
        var pageRows = 26
        var isTUI = true
        var log: [String] = []

        mutating func receive(_ event: TerminalSessionEvent) {
            let (takeHeldFrame, release) = hold.arrived(event, isTUI: isTUI, heldRows: heldRows, pageRows: pageRows)
            if case .output(let data) = event, data == TerminalKeyboardReplayHold.mirrorReset, takeHeldFrame { log.append("held-frame") }
            if release.takeHeldFrame { log.append("held-frame") }
            switch event {
            case .output(let data): queue.append(data)
            case .hostGrid(let columns, let rows): queue.append(hostGrid: columns, rows: rows)
            case .alternateScreen(let on): queue.append(alternateScreen: on)
            default: break
            }
            pump()
        }

        mutating func keyboardStopped() {
            if hold.keyboardStopped().takeHeldFrame { log.append("held-frame") }
            pump()
        }

        mutating func pump() {
            while !hold.holdsAt(nextIsGrid: queue.nextHostGrid != nil), let step = queue.next() {
                switch step {
                case .hostGrid(_, let rows):
                    hold.gridTaken()
                    log.append("grid \(rows)")
                case .bytes(let data): log.append("fed " + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "ESC"))
                case .alternateScreen(let on): log.append("alternate \(on)")
                default: break
                }
            }
        }
    }

    private func session() -> (DaemonTerminalSession, () -> [TerminalSessionEvent]) {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var seen: [TerminalSessionEvent] = []
        session.start { seen.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 53, "rows": 40,
                                                "data": Data("\u{1B}[?1049hvim".utf8).base64EncodedString()]))
        seen.removeAll()
        return (session, { defer { seen.removeAll() }; return seen })
    }

    private func resized(_ session: DaemonTerminalSession, rows: Int) {
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": rows,
                                                "replay": Data("\u{1B}[?1049hvim\(rows)".utf8).base64EncodedString()]))
    }

    @Test func theRedrawWaitsForTheKeyboardAndItsHeldFrameIsTakenWhenFed() {
        let (session, events) = session()
        var page = Page()
        page.hold.keyboardStarted()
        page.receive(.output(Data("echo".utf8)))
        resized(session, rows: 26)
        let order = events()
        #expect(order.contains(.hostGrid(columns: 53, rows: 26)))
        for event in order { page.receive(event) }
        // The echo went out; the grid, its reset and the replay wait.
        #expect(page.log == ["fed echo"])
        page.keyboardStopped()
        #expect(page.log == ["fed echo", "held-frame", "grid 26", "fed ESCc\u{1B}[?1049hvim26".replacingOccurrences(of: "\u{1B}", with: "ESC")])
        #expect(!page.hold.holding && !page.hold.resetDeferred && !page.hold.gridPending)
    }

    @Test func aDisconnectInTheHoldEndsIt() {
        let (session, events) = session()
        var page = Page()
        page.hold.keyboardStarted()
        resized(session, rows: 26)
        for event in events() { page.receive(event) }
        #expect(page.hold.holding)
        session.setMacOffline(true)
        let change = events()
        #expect(change.contains { if case .connection = $0 { true } else { false } }, "the session reports the link (\(change))")
        for event in change { page.receive(event) }
        #expect(!page.hold.holding && !page.hold.resetDeferred && !page.hold.gridPending)
        #expect(page.log.first == "held-frame")
        #expect(page.log.contains("grid 26"))
        // Nothing is left for the keyboard's stop, and a later reset is not deferred.
        page.keyboardStopped()
        #expect(page.log.filter { $0 == "held-frame" }.count == 1)
    }

    @Test func leavingTheAlternateScreenInTheHoldEndsIt() {
        let (session, events) = session()
        var page = Page()
        page.hold.keyboardStarted()
        resized(session, rows: 26)
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7,
                                                "data": Data("\u{1B}[?1049l$ ".utf8).base64EncodedString()]))
        let order = events()
        #expect(order.contains(.alternateScreen(false)))
        for event in order { page.receive(event) }
        #expect(!page.hold.holding && !page.hold.resetDeferred && !page.hold.gridPending)
        #expect(page.log.first == "held-frame")
        #expect(page.log.contains("alternate false"))
    }
}
