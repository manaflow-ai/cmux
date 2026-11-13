import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Aziz, 2026-11-12: "ensure that the phone never sees a terminal size that
/// it doesn't want to see even if it receives it. This would otherwise cause
/// momentary incorrect size drawings". On screen, a grid other than the one
/// the phone claims (its lease ended over a slow link, a reattach replayed
/// the Mac's grid) is held, the phone claims its grid again at once, and the
/// held grid shows only when the Mac keeps it past the wait.
///
/// And the background case ("I had backgrounded the ios app at that point
/// and it was still showing the iphone size on Mac"): the release and the
/// lease refresh go out at once, never behind a request waiting for its
/// answer, and a daemon with `size-lease-v2` gets the 2 s refresh of its 8 s
/// lease.
@MainActor @Suite struct DaemonTerminalShownGridTests {
    private static let wide = Data("wide-rows".utf8)
    private static let narrow = Data("narrow-rows".utf8)
    private static let reset = Data("\u{1B}c".utf8)

    final class Box { var events: [TerminalSessionEvent] = [] }

    private func grid(_ event: String, _ columns: Int, _ rows: Int, _ data: Data) -> Data {
        FakeTerminalDaemon.line(["event": event, "surface": 7, "cols": columns, "rows": rows,
                                 event == "resized" ? "replay" : "data": data.base64EncodedString()])
    }

    private func commands(_ daemon: FakeTerminalDaemon, _ cmd: String) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == cmd }
    }

    private func session(_ daemon: FakeTerminalDaemon) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
    }

    /// Attached, on screen, showing the phone's 50x20 grid. The fake Mac
    /// replays its own 80x24 on attach and never answers a claim with a
    /// grid change, so the attach's hold runs out first (`reclaimWait` short
    /// here), then the phone's grid arrives.
    private func attachedAtPhoneGrid(_ daemon: FakeTerminalDaemon, wait: Duration) async throws -> (DaemonTerminalSession, Box) {
        daemon.afterAttach = nil
        let session = session(daemon)
        session.reclaimWait = .milliseconds(20)
        let box = Box()
        session.resize(columns: 50, rows: 20)
        session.start { box.events.append($0) }
        try await waitUntil { session.isAttached && box.events.contains(.hostGrid(columns: 80, rows: 24)) }
        session.handle(grid("resized", 50, 20, Data("screen".utf8)))
        try await waitUntil { box.events.contains(.hostGrid(columns: 50, rows: 20)) }
        session.reclaimWait = wait
        box.events.removeAll()
        return (session, box)
    }

    @Test func aShownPageHoldsAGridItDidNotAskForAndClaimsItsOwnAgain() async throws {
        let daemon = FakeTerminalDaemon()
        let (session, box) = try await attachedAtPhoneGrid(daemon, wait: .seconds(30))
        defer { session.stop() }
        let claims = commands(daemon, "resize-surface").count

        // The Mac's grid comes back while the page is on screen (the lease
        // ended over a slow link): not drawn.
        session.handle(grid("resized", 120, 40, Self.wide))
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("more".utf8).base64EncodedString()]))
        #expect(!box.events.contains(.hostGrid(columns: 120, rows: 40)), "the page never takes a grid it did not ask for")
        #expect(!box.events.contains(.output(Self.wide)))
        #expect(!box.events.contains(.output(Data("more".utf8))))

        // The phone claims its grid again at once.
        try await waitUntil { commands(daemon, "resize-surface").count == claims + 1 }
        let claim = try #require(commands(daemon, "resize-surface").last)
        #expect(claim["cols"] as? Int == 50)
        #expect(claim["rows"] as? Int == 20)

        // The Mac answers at the phone's grid: what was held is superseded.
        session.handle(grid("resized", 50, 20, Self.narrow))
        #expect(!box.events.contains(.output(Self.wide)), "the Mac's replay is never drawn")
        #expect(box.events.contains(.output(Self.reset)))
        #expect(box.events.last == .output(Self.narrow))
    }

    @Test func aGridTheMacKeepsShowsAfterTheWaitAndItsLaterChangesShowAtOnce() async throws {
        let daemon = FakeTerminalDaemon()
        let (session, box) = try await attachedAtPhoneGrid(daemon, wait: .milliseconds(20))
        defer { session.stop() }

        // The Mac's policy keeps another grid (Prefer this Mac): shown after the wait.
        session.handle(grid("resized", 120, 40, Self.wide))
        #expect(!box.events.contains(.output(Self.wide)))
        try await waitUntil { box.events.contains(.output(Self.wide)) }
        let gridAt = box.events.firstIndex(of: .hostGrid(columns: 120, rows: 40))
        let wideAt = box.events.firstIndex(of: .output(Self.wide))
        #expect(gridAt != nil && wideAt != nil && gridAt! < wideAt!)

        // It keeps setting the grid: each change shows as it comes, no new wait.
        box.events.removeAll()
        session.handle(grid("resized", 100, 30, Data("mac".utf8)))
        #expect(box.events.contains(.hostGrid(columns: 100, rows: 30)))
        #expect(box.events.last == .output(Data("mac".utf8)))
    }

    @Test func theReleaseGoesOutWhileAResizeWaitsForItsAnswer() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredResizes = true
        let session = session(daemon)
        defer { session.stop() }
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached && commands(daemon, "resize-surface").count == 1 }

        // The app goes to the background while that resize's answer is stuck
        // behind the terminal's output: the release does not wait for it.
        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        #expect(commands(daemon, "release-surface-size").first?["surface"] as? Int == 7)
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
