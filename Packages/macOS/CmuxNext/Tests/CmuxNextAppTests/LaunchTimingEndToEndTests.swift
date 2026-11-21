import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// A launch timing, end to end: the real Sentry SDK with the app's options sends it, and a local server receives
/// the envelope. Its transaction holds the fixed fields only: the two measurements, the two tags, the release and
/// environment, and no user, device, OS or app context, install id or other identifier.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchTimingEndToEndTests {
    @Test func theTransactionReachesTheServerWithOnlyTheFixedFields() async throws {
        let server = try EnvelopeServer()
        let port = try await server.start()
        defer { server.stop() }
        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0.0-nightly.e2e", build: "4242",
                                          isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])
        let reporter = CrashReporter(policy: policy, identity: CrashReportIdentity(installID: "0E2E0E2E-0000-4000-8000-000000000001", commit: "a893e2e0"))
        let options = reporter.options()
        options.dsn = "http://e2e0000000000000000000000000000e@127.0.0.1:\(port)/1"
        options.enableCrashHandler = false
        options.enableAppHangTracking = false
        options.enableSwizzling = false
        options.enableAutoSessionTracking = false
        SentrySDK.start(options: options)
        defer { SentrySDK.close() }

        LaunchTiming(firstFrameMs: 312.3, firstInteractionMs: 455, kind: .cold, workspaces: .some).capture()
        SentrySDK.flush(timeout: 10)

        let envelope = try #require(await server.firstEnvelope(timeout: .seconds(15)), "no envelope reached the server")
        let transaction = try #require(SentryEnvelopeReader.item("transaction", in: envelope), "the envelope holds no transaction")
        #expect(transaction["transaction"] as? String == "cmux.launch")
        #expect(transaction["release"] as? String == "cmux-next@1.0.0-nightly.e2e+4242")
        #expect(transaction["environment"] as? String == "nightly-next")
        #expect(SentryEnvelopeReader.tags(of: transaction) == ["launch_kind": "cold", "workspaces": "10-49"])
        let measurements = transaction["measurements"] as? [String: [String: Any]] ?? [:]
        #expect(measurements["launch_first_frame"]?["value"] as? Double == 312.3)
        #expect(measurements["launch_first_interaction"]?["value"] as? Double == 455)
        #expect(measurements.count == 2)
        #expect(transaction["user"] == nil, "no user: \(String(describing: transaction["user"]))")
        let contexts = transaction["contexts"] as? [String: Any] ?? [:]
        #expect(Set(contexts.keys).isSubset(of: ["trace"]), "contexts: \(contexts.keys.sorted())")
        for key in ["extra", "breadcrumbs", "debug_meta", "modules", "server_name", "request", "threads", "exception"] {
            #expect(transaction[key] == nil, "\(key) was sent")
        }
        let text = String(decoding: envelope, as: UTF8.self)
        #expect(!text.contains("0E2E0E2E"), "the install id left the Mac")
    }
}
