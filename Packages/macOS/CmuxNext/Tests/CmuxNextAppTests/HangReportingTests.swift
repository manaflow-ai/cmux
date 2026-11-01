import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// What cmux-next NIGHTLY sends to crash reporting for main-thread hangs and hitches
/// (2026-10-30: Lawrence had 3 hangs in 30 s on Oct 29 and Sentry got one; no report said
/// whose Mac or which commit; hitches under 250 ms never left the Mac).
@Suite struct HangReportingTests {
    private static let ms: UInt64 = 1_000_000
    private static let minute: UInt64 = 60_000 * ms

    @Test func everyHangIsSentNotOnePerFiveMinutes() {
        let sent = Box<[MainThreadHangEvent]>([])
        let clock = Box<UInt64>(0)
        let reporter = MainThreadHangReporter(budget: MainThreadHangReporter.defaultBudget(), isEnabled: { true }, summary: nil,
                                              sink: { event in sent.value.withLock { $0.append(event) } },
                                              uptime: { clock.value.withLock { $0 } })
        for second in [0, 10, 25] {
            clock.value.withLock { $0 = UInt64(second) * 1_000 * Self.ms }
            #expect(reporter.noteHang(duration: .seconds(2), addresses: [1, 2, 3]))
        }
        #expect(sent.value.withLock { $0.count } == 3)
        #expect(sent.value.withLock { $0.first?.addresses } == [1, 2, 3])
    }

    @Test func theWatchdogHasNoIntervalBetweenHangReports() {
        #expect(MainThreadWatchdog.Configuration().hangReportInterval == .zero)
        #expect(MainThreadWatchdog.Configuration().hangThreshold == .seconds(2))
    }

    @Test func aHangFloodIsBudgetedAndTheDroppedHangsAreCounted() {
        let reports = Box<[StallSummaryReport]>([])
        let clock = Box<UInt64>(0)
        let summary = StallSummaryRecorder(summary: StallSummary(), isEnabled: { true },
                                           sink: { report, _ in reports.value.withLock { $0.append(report) } },
                                           uptime: { clock.value.withLock { $0 } })
        let reporter = MainThreadHangReporter(budget: MainThreadHangReporter.defaultBudget(), isEnabled: { true }, summary: summary,
                                              sink: { _ in }, uptime: { clock.value.withLock { $0 } })
        let admitted = (0..<40).filter { _ in reporter.noteHang(duration: .seconds(2), addresses: []) }.count
        #expect(admitted == 30)
        clock.value.withLock { $0 = 2 * Self.minute }
        #expect(reporter.noteHang(duration: .seconds(2), addresses: []), "a token comes back each minute")
        summary.close()
        let report = reports.value.withLock { $0.last }
        #expect(report?.hangsSent == 31)
        #expect(report?.hangsDropped == 10)
    }

    @Test func nothingIsSentWhileReportingIsOff() {
        let reporter = MainThreadHangReporter(budget: MainThreadHangReporter.defaultBudget(), isEnabled: { false }, summary: nil,
                                              sink: { _ in Issue.record("sent while off") })
        #expect(!reporter.noteHang(duration: .seconds(3), addresses: []))
    }

    @Test func everyEventNamesTheTeamMemberCommitAndInstall() {
        let member = CrashReportIdentity.member(userID: "u-1", name: " Leo ", email: "leo@example.com",
                                                teamIDs: ["other", CrashReportIdentity.cmuxTeamID])
        #expect(member == CrashTeamMember(id: "u-1", name: "Leo"))
        let identity = CrashReportIdentity(installID: "11111111-2222-3333-4444-555555555555",
                                           commit: "6c1a5ab8bf34b8f11a80c202460d56504d292edb", member: member)
        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0.0", build: "7",
                                          isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false,
                                          processEnvironment: [:])
        let event = Event(level: .error)
        CrashEventLabels(policy: policy).apply(to: event, identity: identity)
        #expect(event.tags?["reporter"] == "Leo")
        #expect(event.tags?["reporter_id"] == "u-1")
        #expect(event.tags?["commit"] == "6c1a5ab8bf34")
        #expect(event.tags?["install"] == "11111111-2222-3333-4444-555555555555")
        #expect(event.tags?["app"] == "cmux-next")
        #expect(event.tags?["channel"] == "nightly")
    }

    @Test func onlyCmuxTeamMembersAreNamed() {
        #expect(CrashReportIdentity.member(userID: "u-2", name: "Someone", email: nil, teamIDs: ["another-team"]) == nil)
        #expect(CrashReportIdentity.member(userID: nil, name: "Someone", email: nil, teamIDs: [CrashReportIdentity.cmuxTeamID]) == nil)
        #expect(CrashReportIdentity.member(userID: "u-3", name: nil, email: "aziz@example.com",
                                           teamIDs: [CrashReportIdentity.cmuxTeamID])?.name == "aziz")
        let anonymous = CrashReportIdentity(installID: "id", commit: nil, member: nil)
        #expect(anonymous.tags["reporter"] == nil)
        #expect(anonymous.tags["install"] == "id")
    }

    @Test func theReporterUsesTheMemberSetAfterSignIn() {
        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1", build: "1", isDebugBuild: false,
                                          telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])
        let reporter = CrashReporter(policy: policy, identity: CrashReportIdentity(installID: "i", commit: "c"))
        reporter.setTeamMember(CrashTeamMember(id: "u", name: "Austin"))
        let event = Event(level: .error)
        _ = reporter.options().beforeSend?(event)
        #expect(event.tags?["reporter"] == "Austin")
        #expect(event.tags?["install"] == "i")
        reporter.setTeamMember(nil)
        let later = Event(level: .error)
        _ = reporter.options().beforeSend?(later)
        #expect(later.tags?["reporter"] == nil)
    }

    @Test func theInstallIDIsMadeOnceAndKept() throws {
        let suite = "hang-reporting-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CrashReportIdentity.installID(in: defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(CrashReportIdentity.installID(in: defaults) == first)
    }

    @Test func shortHitchesAreCountedPerHourAndSentWhenTheHourCloses() {
        var summary = StallSummary()
        for (ms, at) in [(60, 0), (120, 1), (300, 2), (700, 3), (1_500, 4), (2_400, 5), (40, 6)] {
            #expect(summary.record(.stall(nanos: UInt64(ms) * Self.ms), nowNanos: UInt64(at) * Self.minute) == nil)
        }
        #expect(summary.record(.hang(sent: true), nowNanos: 7 * Self.minute) == nil)
        #expect(summary.record(.spikeSent, nowNanos: 8 * Self.minute) == nil)
        let closed = summary.record(.stall(nanos: 80 * Self.ms), nowNanos: 61 * Self.minute)
        let report = closed
        #expect(report?.windowMinutes == 61)
        #expect(report?.stalls == ["50-100ms": 1, "100-250ms": 1, "250-500ms": 1, "500ms-1s": 1, "1-2s": 1, "2s+": 1])
        #expect(report?.hangsSent == 1)
        #expect(report?.spikesSent == 1)
        #expect(report?.totalStalls == 6, "a 40 ms stall is under the floor")
        // The new hour holds the stall that closed the old one.
        let atQuit = summary.close(nowNanos: 62 * Self.minute)
        #expect(atQuit?.stalls["50-100ms"] == 1)
        #expect(atQuit?.totalStalls == 1)
        #expect(summary.close(nowNanos: 63 * Self.minute) == nil, "an empty window sends nothing")
    }

    @Test func theSummaryEventIsOneIssueWithSearchableCounts() {
        let report = StallSummaryReport(windowMinutes: 60, stalls: ["50-100ms": 12, "2s+": 1], hangsSent: 1, hangsDropped: 0, spikesSent: 3)
        let event = report.event()
        #expect(event.level == .info)
        #expect(event.fingerprint == ["main_thread_stall_summary"])
        #expect(event.tags?["hang_source"] == "stall_summary")
        #expect(event.tags?["stalls_50-100ms"] == "12")
        #expect(event.tags?["stalls_total"] == "13")
        #expect(event.extra?["hangs_sent"] as? Int == 1)
        #expect(event.extra?["stalls_100-250ms"] as? Int == 0)
    }

    @Test func lagSpikesFeedTheSummary() {
        let reports = Box<[StallSummaryReport]>([])
        let summary = StallSummaryRecorder(summary: StallSummary(), isEnabled: { true },
                                           sink: { report, _ in reports.value.withLock { $0.append(report) } }, uptime: { 0 })
        let lag = LagSpikeReporter(limiter: LagSpikeRateLimiter(minimumNanos: 250 * Self.ms), isEnabled: { true }, summary: summary,
                                   sink: { _ in }, uptime: { 0 })
        lag.noteStall(duration: .milliseconds(90), cpu: .milliseconds(90), addresses: [])
        lag.noteStall(duration: .milliseconds(400), cpu: .milliseconds(400), addresses: [])
        summary.close()
        let report = reports.value.withLock { $0.last }
        #expect(report?.totalStalls == 2)
        #expect(report?.spikesSent == 1)
    }
}

/// A lock-guarded value the test's sinks and clocks share.
private nonisolated final class Box<Value: Sendable>: Sendable {
    let value: Mutex<Value>
    init(_ initial: Value) { value = Mutex(initial) }
}
