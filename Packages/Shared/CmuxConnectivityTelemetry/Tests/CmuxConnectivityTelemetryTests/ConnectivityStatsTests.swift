import Foundation
import os
import Testing
@testable import CmuxConnectivityTelemetry

/// The bodies uploads saw, and what each upload answers.
private final class UploadLog: Sendable {
    private let state = OSAllocatedUnfairLock<(bodies: [Data], answers: [ConnectivityStats.UploadResult])>(initialState: ([], []))

    init(answers: [ConnectivityStats.UploadResult] = []) {
        state.withLock { $0.answers = answers }
    }

    var upload: ConnectivityStats.Upload {
        { [self] body in
            state.withLock { state in
                state.bodies.append(body)
                return state.answers.isEmpty ? .sent : state.answers.removeFirst()
            }
        }
    }

    var bodies: [[String: Any]] {
        state.withLock { $0.bodies }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

@Suite("Connectivity stats")
struct ConnectivityStatsTests {
    let client = ConnectivityStats.Client(platform: "ios", appVersion: "1.0", build: "42", osVersion: "26.5", channel: "dev")
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func connect(_ seconds: Double = 0, ms: Double = 812) -> ConnectivityStat {
        ConnectivityStat(.macConnect, outcome: .success, ms: ms, fields: [
            "transport": .code("direct"), "attempts": .number(2), "cold": .flag(true),
            "mac_id": .text("mac-123"), "error": .text("udp 100.70.1.2 refused"),
        ], date: start.addingTimeInterval(seconds))
    }

    @Test func teamUploadCarriesDetail() async throws {
        let stats = ConnectivityStats()
        let log = UploadLog()
        stats.setAudience(.team)
        stats.configure(client: client, upload: log.upload)
        stats.add(connect())
        await stats.flush()
        let body = try #require(log.bodies.first)
        #expect(body["schema"] as? Int == 1)
        #expect((body["client"] as? [String: String])?["channel"] == "dev")
        let stat = try #require((body["stats"] as? [[String: Any]])?.first)
        #expect(stat["name"] as? String == "mac_connect")
        #expect(stat["outcome"] as? String == "success")
        #expect(stat["ms"] as? Double == 812)
        #expect((stat["fields"] as? [String: Any])?["transport"] as? String == "direct")
        #expect((stat["detail"] as? [String: String])?["mac_id"] == "mac-123")
    }

    @Test func everyoneUploadHasNoText() async throws {
        let stats = ConnectivityStats()
        let log = UploadLog()
        stats.configure(client: client, upload: log.upload)
        stats.add(connect())
        await stats.flush()
        let body = try #require(log.bodies.first)
        let stat = try #require((body["stats"] as? [[String: Any]])?.first)
        #expect(stat["detail"] == nil)
        let fields = try #require(stat["fields"] as? [String: Any])
        #expect(Set(fields.keys) == ["transport", "attempts", "cold"])
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        #expect(!raw.contains("mac-123"))
        #expect(!raw.contains("100.70"))
    }

    @Test func wireDropsUnsafeKeysAndNonFiniteNumbers() throws {
        let stat = ConnectivityStat(.tabOpen, outcome: .success, ms: 12.6, fields: [
            "kind": .code("terminal"), "bad key": .code("x"), "nan": .number(.nan), "inf": .number(.infinity),
        ], date: start)
        let wire = stat.wire(for: .team)
        #expect(wire["ms"] as? Double == 13)
        #expect((wire["fields"] as? [String: Any]).map { Set($0.keys) } == ["kind"])
        #expect(ConnectivityStat(.tabOpen, outcome: .success, ms: -5).ms == 0)
        #expect(ConnectivityStat(.tabOpen, outcome: .success, ms: .infinity).ms == 0)
    }

    @Test func everyoneHourlyBudgetCountsDrops() {
        var configuration = ConnectivityStats.Configuration()
        configuration.everyonePerHour = 3
        let stats = ConnectivityStats(configuration: configuration)
        for second in 0..<5 { stats.add(connect(Double(second))) }
        let full = stats.waiting
        #expect(full.pending == 3)
        #expect(full.dropped == 2)
        stats.add(connect(3601))
        #expect(stats.waiting.pending == 4)
    }

    @Test func capacityDropsTheOldest() async throws {
        var configuration = ConnectivityStats.Configuration()
        configuration.capacity = 3
        configuration.flushAt = 100
        let stats = ConnectivityStats(configuration: configuration)
        stats.setAudience(.team)
        for ms in [1.0, 2, 3, 4, 5] { stats.add(connect(ms: ms)) }
        #expect(stats.waiting.pending == 3)
        #expect(stats.waiting.dropped == 2)
        let log = UploadLog()
        stats.configure(client: client, upload: log.upload)
        await stats.flush()
        let sent = (log.bodies.first?["stats"] as? [[String: Any]])?.compactMap { $0["ms"] as? Double }
        #expect(sent == [3, 4, 5])
    }

    @Test func flushSendsBatchesAndKeepsWhatMustWait() async {
        var configuration = ConnectivityStats.Configuration()
        configuration.batchSize = 2
        configuration.flushAt = 100
        let stats = ConnectivityStats(configuration: configuration)
        let log = UploadLog(answers: [.sent, .retryLater])
        stats.configure(client: client, upload: log.upload)
        for second in 0..<5 { stats.add(connect(Double(second))) }
        await stats.flush()
        #expect(log.bodies.count == 2)
        #expect(stats.waiting.pending == 3)
        await stats.flush()
        #expect(log.bodies.count == 4)
        #expect(stats.waiting.pending == 0)
    }

    @Test func aRefusedBatchIsDropped() async {
        let stats = ConnectivityStats()
        let log = UploadLog(answers: [.discard])
        stats.configure(client: client, upload: log.upload)
        stats.add(connect())
        await stats.flush()
        #expect(stats.waiting.pending == 0)
    }

    @Test func leavingTheTeamDropsWaitingStats() {
        let stats = ConnectivityStats()
        stats.setAudience(.team)
        stats.add(connect())
        stats.setAudience(.everyone)
        #expect(stats.waiting.pending == 0)
    }

    @Test func recorderSendsAStatAndKeepsALocalRecord() async throws {
        let telemetry = ConnectivityTelemetry()
        telemetry.setAudience(.team)
        let seen = OSAllocatedUnfairLock<[ConnectivityRecord]>(initialState: [])
        telemetry.addSink { record in seen.withLock { $0.append(record) } }
        telemetry.stat(connect())
        await telemetry.flush()
        let record = try #require(seen.withLock { $0 }.first)
        #expect(record.key == "link.stat_mac_connect")
        #expect(record.fields["ms"] == .number(812))
        #expect(telemetry.stats.waiting.pending == 1)
    }

    /// Stats cleared while an upload runs (leaving the team) and new ones added then: the
    /// finished upload removes only what it sent, so the new stat waits for the next one.
    @Test func anUploadRemovesOnlyWhatItSent() async {
        let stats = ConnectivityStats()
        stats.setAudience(.team)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        stats.configure(client: client) { _ in
            // The first upload waits for the test; the next (the stat added meanwhile) waits for later.
            guard calls.withLock({ calls in defer { calls += 1 }; return calls == 0 }) else { return .retryLater }
            entered.continuation.yield()
            for await _ in release.stream { break }
            return .sent
        }
        stats.add(connect())
        stats.add(connect(1))
        async let flushed: Void = stats.flush()
        for await _ in entered.stream { break }
        stats.setAudience(.everyone)
        stats.add(connect(2))
        release.continuation.yield()
        await flushed
        #expect(stats.waiting.pending == 1)
    }

    @Test func signingOutStopsUploadsAndDropsWaitingStats() async {
        let stats = ConnectivityStats()
        let log = UploadLog()
        stats.configure(client: client, upload: log.upload)
        stats.add(connect())
        stats.stopUploads()
        await stats.flush()
        stats.add(connect(1))
        await stats.flush()
        #expect(log.bodies.isEmpty)
        #expect(stats.waiting.pending == 1)
    }

    @Test func aTabStillOpeningAtTheBackgroundIsCancelled() async throws {
        let telemetry = ConnectivityTelemetry()
        let open = ConnectivityTabTimer(kind: "terminal", cached: false, telemetry: telemetry)
        let other = ConnectivityTabTimer(kind: "agent", cached: false, telemetry: telemetry)
        other.finish(cached: true, telemetry: telemetry)
        telemetry.stats.appWentToBackground()
        open.finish(telemetry: telemetry)
        let log = UploadLog()
        telemetry.stats.configure(client: client, upload: log.upload)
        await telemetry.stats.flush()
        let sent = try #require(log.bodies.first?["stats"] as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent[0]["outcome"] as? String == "success")
        #expect((sent[0]["fields"] as? [String: Any])?["cached"] as? Bool == true)
        #expect(sent[1]["outcome"] as? String == "cancelled")
        #expect((sent[1]["fields"] as? [String: Any])?["cause"] as? String == "background")
    }

    @Test func stopwatchMeasuresMilliseconds() {
        let start = ContinuousClock.now
        let watch = ConnectivityStopwatch(start: start)
        #expect(watch.elapsedMilliseconds(at: start.advanced(by: .milliseconds(1500))) == 1500)
        #expect(watch.elapsedMilliseconds(at: start.advanced(by: .microseconds(2400))) == 2)
    }
}
