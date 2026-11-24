import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The live session under a projecting page (`TerminalProjectingSession`,
/// review follow-up F1 on #45381): the page shows a full-screen app at the
/// Mac's own grid, zoomed, and claims the phone's size only for a fit. A
/// page that is on screen and stops claiming (Keep the Mac's Size, or the
/// fitted program left) must show the Mac's grid and its output as they
/// come; only a hidden page holds them for its return.
///
/// Each test drives `DaemonTerminalSession` as `TerminalProjectingSession`
/// does: `setProjectsLocally(true)` and no claim at first, then
/// `resize` and `setClaimsSize(true)` for a fit, `setClaimsSize(false)` for
/// its release.
@MainActor @Suite struct DaemonTerminalProjectedClaimTests {
    private static let fitted = Data("fitted-rows".utf8)
    private static let wide = Data("wide-rows".utf8)
    private static let more = Data("more".utf8)

    final class Box { var events: [TerminalSessionEvent] = [] }

    private func grid(_ columns: Int, _ rows: Int, _ replay: Data) -> Data {
        FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": columns, "rows": rows,
                                 "replay": replay.base64EncodedString()])
    }

    private func output(_ data: Data) -> Data {
        FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": data.base64EncodedString()])
    }

    private func commands(_ daemon: FakeTerminalDaemon, _ cmd: String) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == cmd }
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    /// Attached under a projecting page, htop on the alternate screen, fitted
    /// to the phone's 50x20 (typed into), the Mac answered at that grid.
    private func fittedAlternateScreen(_ daemon: FakeTerminalDaemon) async throws -> (DaemonTerminalSession, Box) {
        daemon.afterAttach = nil
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.reclaimWait = .milliseconds(20)
        session.setProjectsLocally(true)
        session.setClaimsSize(false)
        let box = Box()
        session.start { box.events.append($0) }
        try await waitUntil { session.isAttached }
        session.handle(output(Data("\u{1B}[?1049hhtop".utf8)))
        try await waitUntil { box.events.contains(.alternateScreen(true)) }

        // Typed into: the wrapper resizes, then claims.
        session.resize(columns: 50, rows: 20)
        session.setClaimsSize(true)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }
        session.handle(grid(50, 20, Self.fitted))
        try await waitUntil { box.events.contains(.output(Self.fitted)) }
        box.events.removeAll()
        return (session, box)
    }

    /// F1: "Keep the Mac's Size" on a fitted full-screen app, page on screen.
    /// Before the fix the Mac's grid and everything after it were held with
    /// no deadline: the page froze on its last fitted frame.
    @Test func keepTheMacsSizeOnScreenShowsTheMacsGridAndLiveOutput() async throws {
        let daemon = FakeTerminalDaemon()
        let (session, box) = try await fittedAlternateScreen(daemon)
        defer { session.stop() }

        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        session.handle(grid(120, 40, Self.wide))
        session.handle(output(Self.more))

        try await waitUntil(attempts: 100) { box.events.contains(.output(Self.more)) }
        let gridAt = box.events.firstIndex(of: .hostGrid(columns: 120, rows: 40))
        let wideAt = box.events.firstIndex(of: .output(Self.wide))
        let moreAt = box.events.firstIndex(of: .output(Self.more))
        #expect(gridAt != nil && wideAt != nil && moreAt != nil, "the page froze: \(box.events)")
        if let gridAt, let wideAt, let moreAt {
            #expect(gridAt < wideAt && wideAt < moreAt, "shown out of order: \(box.events)")
        }
    }

    /// The hidden case keeps its hold: the page leaves (the wrapper says
    /// hidden, then releases the fit), and the Mac's grid waits. Back on
    /// screen with no claim (the program no longer fitted), it shows at once
    /// instead of waiting forever for a claim that never goes out.
    @Test func aHiddenPageHoldsTheMacsGridAndShowsItWhenBackWithoutAClaim() async throws {
        let daemon = FakeTerminalDaemon()
        let (session, box) = try await fittedAlternateScreen(daemon)
        defer { session.stop() }

        session.setPageShown(false)
        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        session.handle(grid(120, 40, Self.wide))
        session.handle(output(Self.more))
        #expect(!box.events.contains(.hostGrid(columns: 120, rows: 40)), "a hidden page drew the Mac's grid")
        #expect(!box.events.contains(.output(Self.more)))

        session.setPageShown(true)
        #expect(box.events.contains(.hostGrid(columns: 120, rows: 40)), "held after the page came back: \(box.events)")
        #expect(box.events.last == .output(Self.more))
        #expect(commands(daemon, "resize-surface").count == 1, "no claim goes out for a page that does not claim")
    }
}
