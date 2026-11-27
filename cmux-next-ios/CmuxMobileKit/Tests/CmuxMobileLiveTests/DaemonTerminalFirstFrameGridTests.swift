import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-23: "im sometimes seeing these 118x69 load ins which are
/// wide... then it properly goes." The session held the Mac's grid back from
/// the screen (`TerminalReclaimHold`) but still answered `remoteColumns` and
/// `remoteRows` with it, and the page lays its mirror out from those before
/// any grid event reaches it: every layout pass while the claim was out
/// sized the mirror at the Mac's 118 columns and panned it sideways, until
/// the phone's own grid came back. The screen reads only the grid it was
/// shown.
@MainActor @Suite struct DaemonTerminalFirstFrameGridTests {
    final class Box { var events: [TerminalSessionEvent] = [] }

    private func grid(_ event: String, _ columns: Int, _ rows: Int, _ data: Data) -> Data {
        FakeTerminalDaemon.line(["event": event, "surface": 7, "cols": columns, "rows": rows,
                                 event == "resized" ? "replay" : "data": data.base64EncodedString()])
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    /// The first attach: the Mac replays its own 80x24 before it answers the
    /// phone's 50x20. The page, laid out meanwhile, never reads the Mac's grid.
    @Test func theFirstFrameIsLaidOutAtThePhonesGrid() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        defer { session.stop() }
        session.reclaimWait = .seconds(30)
        let box = Box()
        session.resize(columns: 50, rows: 20)
        session.start { box.events.append($0) }
        try await waitUntil { session.isAttached }
        #expect(!box.events.contains(.hostGrid(columns: 80, rows: 24)), "the Mac's grid is held while the claim is out")
        #expect(session.remoteColumns != 80, "the page lays out at the phone's columns, never the held Mac grid")
        #expect(session.remoteRows == 20, "the page's rows are the phone's while the Mac's grid is held")
        // The claim is answered: the phone's grid is the one shown.
        session.handle(grid("resized", 50, 20, Data("screen".utf8)))
        #expect(box.events.contains(.hostGrid(columns: 50, rows: 20)))
        #expect(session.remoteColumns == 50 && session.remoteRows == 20)
    }

    /// A hidden page that comes back: the Mac's 118x69 (its pane's own grid
    /// after the release) is held, and the page keeps laying out at 50x20.
    @Test func aHeldMacGridNeverReachesThePagesLayout() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        let box = Box()
        session.start { box.events.append($0) }
        session.resize(columns: 50, rows: 20)
        session.handle(grid("vt-state", 50, 20, Data("screen".utf8)))
        #expect(session.remoteColumns == 50 && session.remoteRows == 20)
        session.setClaimsSize(false)
        session.handle(grid("resized", 118, 69, Data("wide".utf8)))
        #expect(!box.events.contains(.hostGrid(columns: 118, rows: 69)))
        #expect(session.remoteColumns == 50, "held, the Mac's 118 columns never size the mirror")
        #expect(session.remoteRows == 20)
        session.setClaimsSize(true)
        session.handle(grid("resized", 50, 20, Data("narrow".utf8)))
        #expect(session.remoteColumns == 50 && session.remoteRows == 20)
        #expect(!box.events.contains(.hostGrid(columns: 118, rows: 69)))
    }

    /// When the hold does show the Mac's grid (its policy keeps it), the page
    /// reads it then, in step with the grid event.
    @Test func aGridTheHoldShowsIsTheOneThePageReads() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        let box = Box()
        session.start { box.events.append($0) }
        session.resize(columns: 50, rows: 20)
        session.handle(grid("vt-state", 50, 20, Data("screen".utf8)))
        session.setClaimsSize(false)
        session.handle(grid("resized", 118, 69, Data("wide".utf8)))
        #expect(session.remoteColumns == 50)
        // The stream ends while hidden: the hold shows what it has.
        session.handle(FakeTerminalDaemon.line(["event": "detached", "surface": 7, "reason": "closed"]))
        #expect(box.events.contains(.hostGrid(columns: 118, rows: 69)))
        #expect(session.remoteColumns == 118 && session.remoteRows == 69)
    }
}
