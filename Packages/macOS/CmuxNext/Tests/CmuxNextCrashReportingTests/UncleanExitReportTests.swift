import CmuxNextCompat
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p10-stability-203: the previous run's exit outcome, sent once per launch. The first record that names the end
/// wins; the event carries only the outcome, the signal number and two flags, in one issue per outcome; nothing is
/// posted or sent without consent.
struct UncleanExitReportTests {
    private static func report(endedAsAsked: Bool = false, signal: Int32? = nil, exception: Bool = false,
                               crashPathRan: Bool = false, bootChanged: Bool = false) -> UncleanExitReport {
        UncleanExitReport(endedAsAsked: endedAsAsked, signal: signal, exception: exception, crashPathRan: crashPathRan,
                          bootChanged: bootChanged, survived: true, followedRestart: false)
    }

    @Test func theFirstRecordThatNamesTheEndWins() {
        #expect(Self.report(endedAsAsked: true, signal: SIGTERM).outcome == .clean)
        #expect(Self.report(signal: SIGABRT, exception: true, crashPathRan: true).outcome == .exception)
        #expect(Self.report(signal: SIGSEGV, crashPathRan: true, bootChanged: true).outcome == .signal)
        #expect(Self.report(crashPathRan: true, bootChanged: true).outcome == .crashCaught)
        #expect(Self.report(bootChanged: true).outcome == .systemShutdown)
        #expect(Self.report().outcome == .uncleanNoReport, "SIGKILL, jetsam, Force Quit")
    }

    @Test func theSignalIsKeptOnlyForASignalOutcome() {
        #expect(Self.report(signal: SIGSEGV).signal == SIGSEGV)
        #expect(Self.report(signal: SIGABRT, exception: true).signal == nil)
        #expect(Self.report(endedAsAsked: true, signal: SIGTERM).signal == nil)
    }

    @Test func theOutcomeValuesAreTheOnesStabilityHealthReads() {
        #expect(UncleanExitReport.Outcome.allCases.map(\.rawValue)
            == ["clean", "signal", "exception", "crash-caught", "unclean-no-report", "system-shutdown"])
    }

    @Test func theEventHoldsTheOutcomeAndNothingElse() throws {
        let event = UncleanExitReport(endedAsAsked: false, signal: SIGBUS, exception: false, crashPathRan: true,
                                      bootChanged: false, survived: false, followedRestart: true).event()
        #expect(event.level == .warning)
        #expect(event.tags == ["exit_outcome": "signal", "exit_signal": String(SIGBUS), "exit_survived": "no",
                               "exit_followed_restart": "yes"])
        #expect(event.fingerprint == ["previous_run_exit", "signal"])
        #expect(event.message?.formatted == "previous run ended: signal")
        #expect(event.exceptions == nil)
        #expect(event.extra == nil)
        #expect(event.user == nil)
        let clean = Self.report(endedAsAsked: true).event()
        #expect(clean.level == .info)
        #expect(clean.tags?["exit_signal"] == nil)
    }

    // MARK: the send

    /// Runs each post at once and counts them.
    private final class InlineFiles: MayBlockRunner {
        let posts = Atomic(0)
        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            _ = posts.add(1, ordering: .relaxed)
            body()
        }
    }

    /// The outcomes the capture seam got, and how often the consent seam was asked.
    private final class Captured: Sendable {
        let outcomes = Mutex<[String]>([])
        let asks = Atomic(0)
    }

    private static let reporter = CrashReporter(policy: CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:]))

    @Test func withConsentOneEventGoesOutOnTheFilesLane() {
        let work = InlineFiles(), captured = Captured()
        let posted = Self.reporter.reportPreviousExit(Self.report(), work: work, consented: { true }, capture: { event, _ in
            captured.outcomes.withLock { $0.append(event.tags?["exit_outcome"] ?? "none") }
        })
        #expect(posted)
        #expect(work.posts.load(ordering: .relaxed) == 1)
        #expect(captured.outcomes.withLock { $0 } == ["unclean-no-report"])
    }

    @Test func withoutConsentNothingIsPostedOrSent() {
        let work = InlineFiles(), captured = Captured()
        let posted = Self.reporter.reportPreviousExit(Self.report(), work: work, consented: { false }, capture: { event, _ in
            captured.outcomes.withLock { $0.append(event.tags?["exit_outcome"] ?? "none") }
        })
        #expect(!posted)
        #expect(work.posts.load(ordering: .relaxed) == 0)
        #expect(captured.outcomes.withLock { $0 }.isEmpty)
    }

    @Test func consentWithdrawnBeforeTheLaneRunsSendsNothing() {
        let work = InlineFiles(), captured = Captured()
        _ = Self.reporter.reportPreviousExit(Self.report(), work: work,
                                             consented: { captured.asks.add(1, ordering: .relaxed).oldValue == 0 },
                                             capture: { event, _ in
                                                 captured.outcomes.withLock { $0.append(event.tags?["exit_outcome"] ?? "none") }
                                             })
        #expect(captured.outcomes.withLock { $0 }.isEmpty)
    }

    /// A reporter that never started (no consent, a DEV build, tests) sends nothing through the public path.
    @Test func aReporterThatDidNotStartSendsNothing() {
        let work = InlineFiles()
        #expect(!Self.reporter.reportPreviousExit(Self.report(), work: work))
        #expect(work.posts.load(ordering: .relaxed) == 0)
    }
}
