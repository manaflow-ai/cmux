import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CoreFoundation
import Foundation
import Network
import Sentry
import Testing

/// A real main-thread hang, end to end: the app's watchdog sees the main thread blocked for
/// 2.6 s, ``MainThreadHangReporter`` sends it through the real Sentry SDK with the app's options
/// (scrubber, labels, identity), and a local server receives the envelope over HTTP. The test
/// reads the envelope as Sentry's ingest would: the hang's type, the blocked main thread's
/// frames, the build's commit, the install id, the team member, the release and the macOS
/// version. The envelope is written to `artifacts/hang-e2e-envelope.bin` in the checkout, so a
/// fleet step can return it (`cmux-ci run --artifact`) and it can be sent to Sentry's ingest as is.
///
/// Sentry starts with its crash handler, hang tracker and swizzling off and closes at the end:
/// only the event path runs in the test process.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangReportingEndToEndTests {
    @MainActor
    @Test func aForcedHangReachesTheServerWithStackCommitInstallAndMember() async throws {
        let server = try EnvelopeServer()
        let port = try await server.start()
        defer { server.stop() }

        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0.0-nightly.e2e", build: "4242",
                                          isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false,
                                          processEnvironment: [:])
        let reporter = CrashReporter(policy: policy, identity: CrashReportIdentity(installID: "0E2E0E2E-0000-4000-8000-000000000001",
                                                                                   commit: "a893e2e0000000000000000000000000000e2e00"))
        reporter.setTeamMember(CrashTeamMember(id: "a893-e2e", name: "a893 fleet e2e"))
        let options = reporter.options()
        options.dsn = "http://e2e0000000000000000000000000000e@127.0.0.1:\(port)/1"
        options.enableCrashHandler = false
        options.enableAppHangTracking = false
        options.enableSwizzling = false
        options.enableAutoSessionTracking = false
        options.enableNetworkTracking = false
        SentrySDK.start(options: options)
        defer { SentrySDK.close() }

        let sent = SentBox()
        let hangs = MainThreadHangReporter(budget: MainThreadHangReporter.defaultBudget(), isEnabled: { true }, summary: nil,
                                           sink: { event in sent.count.withLock { $0 += 1 }; reporter.reportHangForced(event) })
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false, hangAssertThreshold: nil))
        watchdog.onHang = { hang in
            hangs.noteHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) })
        }
        watchdog.start()
        defer { watchdog.stop() }
        runOneForcedHangOnTheMainRunLoop()
        #expect(sent.count.withLock { $0 } == 1, "the watchdog reported the hang once")
        SentrySDK.flush(timeout: 10)

        let envelope = try #require(await server.firstEnvelope(timeout: .seconds(15)), "no envelope reached the server")
        let event = try #require(SentryEnvelopeReader.event(in: envelope), "the envelope holds no event")
        let exception = try #require(((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
        #expect(exception["type"] as? String == "MainThreadHang")
        let frames = (exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? []
        #expect(frames.count > 3, "the blocked main thread's frames")
        let tags = SentryEnvelopeReader.tags(of: event)
        #expect(tags["commit"] == "a893e2e00000")
        #expect(tags["install"] == "0E2E0E2E-0000-4000-8000-000000000001")
        #expect(tags["reporter"] == "a893 fleet e2e")
        #expect(tags["hang_source"] == "main_thread_watchdog")
        #expect(tags["app"] == "cmux-next")
        #expect(event["release"] as? String == "cmux-next@1.0.0-nightly.e2e+4242")
        #expect(event["environment"] as? String == "nightly-next")
        let os = (event["contexts"] as? [String: Any])?["os"] as? [String: Any]
        #expect((os?["version"] as? String)?.isEmpty == false, "macOS version: \(String(describing: os))")
        let debugImages = ((event["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []
        #expect(!debugImages.isEmpty, "images to symbolicate the stack")

        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../artifacts/hang-e2e-envelope.bin").standardizedFileURL
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try envelope.write(to: out)
    }
}

/// Runs the main run loop once with a 2.6 s block inside one of its sources (the forced hang).
@MainActor
func runOneForcedHangOnTheMainRunLoop() {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        forcedMainThreadHangForE2E(.milliseconds(2_600))
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    CFRunLoopRunInMode(.defaultMode, 30, false)
}

/// Blocks the calling (main) thread for `duration`: the forced hang. Named so its frame shows.
@inline(never)
nonisolated func forcedMainThreadHangForE2E(_ duration: Duration) {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline { usleep(5_000) }
}

nonisolated private extension CrashReporter {
    /// Sends `hang` while Sentry runs in this process (the test started it; ``isStarted`` is only
    /// true after ``start()``, which a test process refuses).
    func reportHangForced(_ hang: MainThreadHangEvent) {
        SentrySDK.capture(event: hang.event())
    }
}

private nonisolated final class SentBox: Sendable {
    let count = Mutex<Int>(0)
}
