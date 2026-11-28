import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-17 (softened): "Surely we can just calculate a terminal size
/// and resize whatever needs exceptions, falling back if need be. Plus the
/// loading of everything needs to be FASTER."
///
/// A first attach sends the grid the page measured with the attach, in the
/// same write as `set-client-info` and `identify` (TerminalAttachPlan): one
/// round trip to the Mac's replay at that grid, not two. A refusal falls back
/// to the attach in series; a reattach stays in series.
@MainActor @Suite struct DaemonTerminalAttachPlanTests {
    private func session(_ daemon: FakeTerminalDaemon, channels: ChannelLog? = nil) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels?.append(channel)
            return DaemonClient(channel: channel)
        }
    }

    private func attaches(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }
    }

    @Test func aFirstAttachSendsItsGridBesideIdentifyInOneWrite() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let session = session(daemon)
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        // One write carries the attach: its answer is one round trip away.
        #expect(daemon.writes.first == ["set-client-info", "identify", "attach-surface"], "\(daemon.writes)")
        let attach = try #require(attaches(daemon).first)
        #expect(attach["cols"] as? Int == 54)
        #expect(attach["rows"] as? Int == 42)
        #expect(attaches(daemon).count == 1)
        // The replay came after the reset (its event lines reach the main
        // actor in their own hop, so maybe just after `.attached`), and the
        // attach already holds the grid: no resize.
        func output() -> String {
            events.compactMap { event -> String? in
                if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
                return nil
            }.joined()
        }
        try await waitUntil { output().count >= "\u{1B}chello\r\n$ ".count }
        #expect(output().hasPrefix("\u{1B}chello\r\n$ "), "\(output().debugDescription)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "resize-surface" })
    }

    /// The exception: a Mac whose daemon does not take a size in the attach
    /// ignores the grid, and the phone's resize after the attach claims it.
    @Test func aDaemonWithoutTheSizedAttachGetsTheResizeAfter() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        defer { session.stop() }
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "resize-surface" } }
        let resize = try #require(daemon.recorded.first { $0["cmd"] as? String == "resize-surface" })
        #expect(resize["cols"] as? Int == 54)
        #expect(resize["rows"] as? Int == 42)
        #expect(attaches(daemon).count == 1)
    }

    /// Falling back: an attach refused for a field it sent (here a lane older
    /// than `replay_history_rows`) is tried again in series, after identify.
    @Test func aRefusedPipelinedAttachFallsBackToTheAttachInSeries() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        daemon.laneRefusesHistoryRows = true
        let session = session(daemon)
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        #expect(attaches(daemon).count == 2)
        #expect(daemon.writes.count >= 2 && daemon.writes[1] == ["attach-surface"], "\(daemon.writes)")
        #expect(attaches(daemon).last?["cols"] as? Int == 54)
        #expect(events.contains(.connection(.attached)))
    }

    /// An attach refused for its surface ("unknown surface": a Mac host that
    /// just restarted) is a failed attach, as in series: one attach-surface a
    /// try, no second one in series behind it, and the retry attaches.
    @Test func anUnknownSurfaceIsOneFailedAttachNotAFallback() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        daemon.failNextAttaches = 1
        let session = session(daemon)
        session.reattachBackoff = []
        defer { session.stop() }
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { if case .failed = session.connectionState { true } else { false } }
        #expect(attaches(daemon).count == 1, "\(daemon.writes)")
        #expect(!session.isAttached)
        session.reconnect()
        try await waitUntil { session.isAttached }
        #expect(attaches(daemon).count == 2)
    }

    /// A hidden terminal claims no size, and a reattach first asks where the
    /// terminal is: both stay in series.
    @Test func aHiddenTerminalAndAReattachAttachInSeries() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let channels = ChannelLog()
        let session = session(daemon, channels: channels)
        defer { session.stop() }
        session.setClaimsSize(false)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        #expect(daemon.writes.first == ["set-client-info", "identify"], "\(daemon.writes)")
        session.setClaimsSize(true)
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        let before = daemon.writes.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        #expect(daemon.writes[before] == ["set-client-info", "identify"], "\(daemon.writes)")
    }

    @Test func thePlan() {
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: (54, 42)) == .pipelined(columns: 54, rows: 42))
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: (54, 42)).roundTrips == 1)
        #expect(TerminalAttachPlan.plan(firstAttach: false, claimsSize: true, size: (54, 42)) == .sequential)
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: false, size: (54, 42)) == .sequential)
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: nil) == .sequential)
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: (0, 42)) == .sequential)
        #expect(TerminalAttachPlan.plan(firstAttach: true, claimsSize: true, size: (54, 42), resumes: true) == .sequential)
        #expect(TerminalAttachPlan.sequential.roundTrips == 2)
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
