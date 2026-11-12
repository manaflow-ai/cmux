import CmuxConnectivityTelemetry
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The link's phase changes turned into connect, reconnect and session stats (LinkConnectStats).
@Suite("Link connect stats")
struct LinkConnectStatsTests {
    let t0 = ContinuousClock.now
    let mac = LinkMachine.Target(macID: "mac-1", name: "Studio", isOnline: true)
    let connecting1 = LinkMachine.Phase.connecting(.wireGuard, attempt: 1)
    let connecting2 = LinkMachine.Phase.connecting(.wireGuard, attempt: 2)
    let waiting = LinkMachine.Phase.waiting(.wireGuard, attempt: 1, reason: "udp 100.70.1.2 timed out", retryIn: .seconds(1))
    let up = LinkMachine.Phase.connected(.wireGuard, .turnTLS, rttMillis: 41)

    func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }

    @Test func firstConnectOfTheLaunch() throws {
        var tracker = LinkConnectStats()
        let started = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        let stats = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 1, path: .turnTLS), at: at(640))
        #expect(started.isEmpty)
        let connect = try #require(stats.first)
        #expect(stats.count == 1)
        #expect(connect.name == .macConnect)
        #expect(connect.outcome == .success)
        #expect(connect.ms == 640)
        #expect(connect.fields["trigger"] == .code("launch"))
        #expect(connect.fields["first_of_launch"] == .flag(true))
        #expect(connect.fields["attempts"] == .number(1))
        #expect(connect.fields["path"] == .code("turn_tls"))
        #expect(connect.fields["transport"] == .code("wireguard"))
        #expect(connect.fields["rtt_ms"] == .number(41))
    }

    @Test func retriesCountAttemptsAndFailures() throws {
        var tracker = LinkConnectStats()
        let steps: [(LinkMachine.Phase, LinkMachine.Phase, LinkMachine.Event, Int)] = [
            (.idle, connecting1, .target(mac), 0),
            (connecting1, waiting, .dialFailed(generation: 1, reason: "timed out"), 300),
            (waiting, connecting2, .retryDue(generation: 2), 1300),
            (connecting2, up, .dialSucceeded(generation: 3, path: .direct), 1800),
        ]
        let stats = steps.flatMap { old, new, event, ms in tracker.change(from: old, to: new, by: event, at: at(ms)) }
        let connect = try #require(stats.first)
        #expect(connect.ms == 1800)
        #expect(connect.fields["attempts"] == .number(2))
        #expect(connect.fields["failures"] == .number(1))
        #expect(connect.fields["last_failure"] == .text("udp 100.70.1.2 timed out"))
    }

    @Test func aDropEndsTheSessionAndTimesTheReconnect() {
        var tracker = LinkConnectStats()
        _ = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        _ = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 1, path: .turnTLS), at: at(500))
        let dropped = tracker.change(from: up, to: connecting1, by: .linkDropped(generation: 1, reason: "peer gone"), at: at(60_500))
        let back = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 2, path: .direct), at: at(61_700))
        #expect(dropped.map(\.name) == [.sessionEnd])
        #expect(dropped.first?.ms == 60_000)
        #expect(dropped.first?.fields["cause"] == .code("dropped"))
        #expect(dropped.first?.fields["reason"] == .text("peer gone"))
        #expect(back.map(\.name) == [.macConnect, .reconnect])
        #expect(back.first?.fields["trigger"] == .code("drop"))
        #expect(back.first?.fields["first_of_launch"] == .flag(false))
        #expect(back.last?.ms == 1200)
        #expect(back.last?.fields["cause"] == .code("dropped"))
    }

    @Test func goingToTheBackgroundIsNoOutage() {
        var tracker = LinkConnectStats()
        _ = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        _ = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 1, path: .direct), at: at(100))
        let left = tracker.change(from: up, to: .idle, by: .background, at: at(5100))
        _ = tracker.change(from: .idle, to: connecting1, by: .foreground, at: at(90_000))
        let back = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 2, path: .direct), at: at(90_300))
        #expect(left.map(\.name) == [.sessionEnd])
        #expect(left.first?.fields["cause"] == .code("background"))
        #expect(back.map(\.name) == [.macConnect])
        #expect(back.first?.fields["trigger"] == .code("foreground"))
        #expect(back.first?.ms == 300)
    }

    @Test func aConnectCutShortByTheBackgroundIsCancelled() {
        var tracker = LinkConnectStats()
        _ = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        let cut = tracker.backgrounded(at: at(2000))
        #expect(cut.map(\.name) == [.macConnect])
        #expect(cut.first?.outcome == .cancelled)
        #expect(cut.first?.fields["cause"] == .code("background"))
        #expect(tracker.backgrounded(at: at(3000)).isEmpty)
    }

    @Test func aMacGoingOfflineFailsTheConnect() {
        var tracker = LinkConnectStats()
        _ = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        let offline = LinkMachine.Target(macID: "mac-1", name: "Studio", isOnline: false)
        let stats = tracker.change(from: connecting1, to: .macOffline, by: .target(offline), at: at(4000))
        #expect(stats.map(\.name) == [.macConnect])
        #expect(stats.first?.outcome == .failure)
        #expect(stats.first?.fields["cause"] == .code("mac_offline"))
        #expect(stats.first?.ms == 4000)
    }

    @Test func aRevokedSessionFailsTheReconnect() {
        var tracker = LinkConnectStats()
        _ = tracker.change(from: .idle, to: connecting1, by: .target(mac), at: at(0))
        _ = tracker.change(from: connecting1, to: up, by: .dialSucceeded(generation: 1, path: .direct), at: at(100))
        _ = tracker.change(from: up, to: connecting1, by: .probeFailed(generation: 1, reason: "no pong"), at: at(1100))
        let stats = tracker.change(from: connecting1, to: .signedOut, by: .signedOut(generation: 2), at: at(2100))
        #expect(stats.map(\.name) == [.macConnect, .reconnect])
        #expect(stats.allSatisfy { $0.outcome == .failure })
        #expect(stats.last?.fields["ended_by"] == .code("signed_out"))
        #expect(stats.last?.ms == 1000)
    }
}
