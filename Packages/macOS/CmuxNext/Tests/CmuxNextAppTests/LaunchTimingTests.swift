import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// The field launch timing (startup-tti): sent only under the crash reports' consent, sampled, and holding only
/// its fixed fields (first frame, first interaction, build, warm or cold, a workspace bucket).
@Suite struct LaunchTimingTests {
    private static func policy(bundleID: String = "com.cmuxterm.app.nightly", debug: Bool = false, optIn: Bool = true,
                               managedOff: Bool = false, environment: [String: String] = [:]) -> CrashReportingPolicy {
        CrashReportingPolicy(bundleID: bundleID, shortVersion: "1.0.0", build: "77", isDebugBuild: debug, telemetryOptIn: optIn,
                             managedDisablesTelemetry: managedOff, processEnvironment: environment)
    }

    @Test func aNightlyWithTheChoiceOnSamplesInsideTheRate() {
        #expect(LaunchTiming.samples(policy: Self.policy(), roll: 0.05))
        #expect(!LaunchTiming.samples(policy: Self.policy(), roll: LaunchTiming.sampleRate))
        #expect(!LaunchTiming.samples(policy: Self.policy(), roll: 0.5))
        #expect(LaunchTiming.sampleRate == 0.1)
    }

    @Test func theManagedPolicyTurnsItOffWhateverTheChoice() {
        #expect(!LaunchTiming.samples(policy: Self.policy(optIn: true, managedOff: true), roll: 0))
    }

    @Test func thePersonsChoiceOffTurnsItOff() {
        #expect(!LaunchTiming.samples(policy: Self.policy(optIn: false), roll: 0))
        let defaults = UserDefaults(suiteName: "launch-timing-\(UUID().uuidString)")!
        defaults.set(false, forKey: CrashReportingPolicy.telemetryKey)
        #expect(!CrashReportingPolicy.telemetryOptIn(in: defaults))
    }

    @Test func devBuildsAreOffUnlessTheDevVariableIsSet() {
        #expect(!LaunchTiming.samples(policy: Self.policy(bundleID: "com.cmuxterm.app.debug.tag"), roll: 0))
        #expect(!LaunchTiming.samples(policy: Self.policy(debug: true), roll: 0))
        #expect(LaunchTiming.samples(policy: Self.policy(bundleID: "com.cmuxterm.app.debug.tag",
                                                         environment: [CrashReportingPolicy.devOptInKey: "1"]), roll: 0))
    }

    @Test func aReporterThatDidNotStartSendsNothing() {
        let reporter = CrashReporter(policy: Self.policy())
        let timing = LaunchTiming(firstFrameMs: 300, firstInteractionMs: 420, kind: .warm, workspaces: .few)
        #expect(!reporter.sendLaunchTimingIfSampled(timing, roll: 0))
    }

    @Test func thePayloadHoldsOnlyTheFixedFields() throws {
        let marks = ["main_start": 40.0, "first_window_frame_committed": 312.34, "window_usable": 455.0,
                     "home.saved_page_shown": 330.0, "cef.ready": 900.0]
        let timing = try #require(LaunchTiming(marks: marks, priorChatLiveMs: nil, firstOfBuild: true, prewarmed: false, workspaceCount: 12))
        #expect(timing.tags == ["launch_kind": "cold", "workspaces": "10-49"])
        #expect(timing.measurements == ["launch_first_frame": 312.3, "launch_first_interaction": 455.0])
    }

    @Test func firstInteractionIsHomeThenTheFrontChatThenTheTerminal() throws {
        let frame = ["first_window_frame_committed": 300.0]
        let home = try #require(LaunchTiming(marks: frame.merging(["window_usable": 500, "terminal.attach_end": 400]) { $1 },
                                             priorChatLiveMs: 450, firstOfBuild: false, prewarmed: false, workspaceCount: 1))
        #expect(home.firstInteractionMs == 500)
        let chat = try #require(LaunchTiming(marks: frame.merging(["terminal.attach_end": 400]) { $1 }, priorChatLiveMs: 450,
                                             firstOfBuild: false, prewarmed: false, workspaceCount: 1))
        #expect(chat.firstInteractionMs == 450)
        let terminal = try #require(LaunchTiming(marks: frame.merging(["terminal.attach_end": 400]) { $1 }, priorChatLiveMs: nil,
                                                 firstOfBuild: false, prewarmed: false, workspaceCount: 1))
        #expect(terminal.firstInteractionMs == 400)
        let none = try #require(LaunchTiming(marks: frame, priorChatLiveMs: nil, firstOfBuild: false, prewarmed: false, workspaceCount: 1))
        #expect(none.firstInteractionMs == nil)
        #expect(none.measurements.keys.sorted() == ["launch_first_frame"])
        #expect(LaunchTiming(marks: ["window_usable": 500], priorChatLiveMs: nil, firstOfBuild: false, prewarmed: false, workspaceCount: 1) == nil)
    }

    @Test func coldIsTheFirstLaunchOfABuildNotPrewarmed() throws {
        let frame = ["first_window_frame_committed": 300.0]
        #expect(try #require(LaunchTiming(marks: frame, priorChatLiveMs: nil, firstOfBuild: true, prewarmed: false, workspaceCount: 0)).kind == .cold)
        #expect(try #require(LaunchTiming(marks: frame, priorChatLiveMs: nil, firstOfBuild: true, prewarmed: true, workspaceCount: 0)).kind == .warm)
        #expect(try #require(LaunchTiming(marks: frame, priorChatLiveMs: nil, firstOfBuild: false, prewarmed: false, workspaceCount: 0)).kind == .warm)
    }

    @Test func workspaceBucketsHaveTheFixedEdges() {
        let cases: [(Int, String)] = [(0, "0"), (1, "1-9"), (9, "1-9"), (10, "10-49"), (49, "10-49"), (50, "50-199"),
                                      (199, "50-199"), (200, "200+"), (5_000, "200+")]
        for (count, bucket) in cases { #expect(LaunchTiming.WorkspaceBucket(count: count).rawValue == bucket, "\(count)") }
    }

    @Test func beforeSendCutsTheTransactionToItsFixedFields() throws {
        let reporter = CrashReporter(policy: Self.policy(), identity: CrashReportIdentity(installID: "0E2E0E2E-0000-4000-8000-000000000001", commit: "abc"))
        let beforeSend = try #require(reporter.options().beforeSend)
        let event = Event(level: .info)
        event.type = "transaction"
        event.transaction = LaunchTiming.transactionName
        event.tags = ["launch_kind": "warm", "workspaces": "1-9", "install": "0E2E0E2E", "os": "macOS"]
        event.user = User(userId: "installation-id")
        event.context = ["device": ["model": "Mac"], "app": ["device_app_hash": "abc"]]
        event.extra = ["path": "/Users/someone"]
        event.serverName = "someones-mac"
        let sent = try #require(beforeSend(event))
        #expect(sent.tags == ["launch_kind": "warm", "workspaces": "1-9"])
        #expect(sent.user == nil)
        #expect(sent.context == nil)
        #expect(sent.extra == nil)
        #expect(sent.serverName == nil)
    }

    @Test func onlyTheLaunchTimingIsTraced() throws {
        let options = CrashReporter(policy: Self.policy()).options()
        let sampler = try #require(options.tracesSampler)
        #expect(sampler(SamplingContext(transactionContext: TransactionContext(name: LaunchTiming.transactionName, operation: "app.launch")))?.doubleValue == 1)
        #expect(sampler(SamplingContext(transactionContext: TransactionContext(name: "ui.load", operation: "ui.load")))?.doubleValue == 0)
        #expect(!options.enableAutoPerformanceTracing)
        #expect(options.tracePropagationTargets.isEmpty)
    }
}
