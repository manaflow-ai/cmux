import CmuxSentryReporting
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-076, p14-energy-101: Sentry adds no idle wakeup and no instrumentation the app does not use. Its
/// app-hang tracker (a thread that posts to the main queue every 1.6 s) is off wherever the main-thread watchdog is
/// the process's one hang watcher (its episodes are the app hangs, `AppHangReporter`), and every option the
/// short-lived CLI turns off (`CLISentryRuntimePolicy`) is off here too or kept for a named reason.
@Suite struct CrashReporterOptionsTests {
    @Test func theWatchdogTurnsSentrysAppHangTrackerOff() {
        let options = Self.reporter(.watchdog).options()
        #expect(!options.enableAppHangTracking, "SentryANRTrackerV1 would wake the main queue every 1.6 s")
        #expect(options.enableCrashHandler)
        #expect(options.enableUncaughtNSExceptionReporting)
    }

    @Test func withoutAWatchdogSentryStillReportsHangsAtEightSeconds() {
        let options = Self.reporter(.sentry).options()
        #expect(options.enableAppHangTracking)
        #expect(options.appHangTimeoutInterval == 8.0)
    }

    @Test func theWatchdogsAppHangThresholdIsTheSDKsFormerTimeout() {
        #expect(CrashReporter.appHangThreshold == .seconds(8))
        #expect(Self.reporter(.sentry).options().appHangTimeoutInterval == 8.0)
    }

    @Test func theReporterKeepsItsHangTracking() {
        #expect(Self.reporter(.watchdog).hangTracking == .watchdog)
        #expect(CrashReporter(policy: Self.policy).hangTracking == .sentry, "the default keeps Sentry's tracker")
    }

    @Test(arguments: [CrashReporter.HangTracking.sentry, .watchdog])
    func noAutoInstrumentationAndNoMetricKit(_ hangTracking: CrashReporter.HangTracking) {
        let options = Self.reporter(hangTracking).options()
        #expect(!options.isTracingEnabled)
        #expect(!options.enableAutoPerformanceTracing, "no network, file I/O or Core Data spans")
        #expect(!options.enableMetricKit)
        #expect(!options.enableLogs)
        #expect(!options.enableCaptureFailedRequests)
        // The one macOS swizzle the app uses: NSApplication reportException:.
        #expect(options.enableSwizzling)
    }

    /// Audit 17: no request address reaches Sentry. The SDK's URLSession breadcrumb holds every request's
    /// address, query and fragment: the omnibox suggest request (`q=` what the person typed, private profiles
    /// too), a page saved or probed in the browser, the weather lookup's place. A query key such as `q` names
    /// no secret, so the scrubber kept the value. The breadcrumb is off, and an http breadcrumb that still
    /// reaches the scrubber loses its query and fragment.
    @Test(arguments: [CrashReporter.HangTracking.sentry, .watchdog])
    func noRequestAddressReachesSentry(_ hangTracking: CrashReporter.HangTracking) throws {
        let options = Self.reporter(hangTracking).options()
        #expect(!options.enableNetworkBreadcrumbs, "URLSession breadcrumbs carry each request's address")
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.type = "http"
        crumb.data = [
            "url": "https://suggestqueries.google.com/complete/search",
            "method": "GET",
            "status_code": 200,
            "http.query": "client=firefox&q=ssh%20prod-db%20private%20words",
            "http.fragment": "private-fragment",
        ]
        let before = try #require(options.beforeBreadcrumb)
        let sent = try #require(before(crumb))
        let data = sent.data ?? [:]
        #expect(data["http.query"] == nil, "the typed query left in the breadcrumb")
        #expect(data["http.fragment"] == nil)
        #expect(!String(describing: data).contains("private"))
        #expect(data["method"] as? String == "GET")
    }

    /// Each switch the CLI policy sets is the same here, or kept on for a reason the app has and a CLI run has not.
    @Test func everyCLIOffSwitchIsOffOrKeptForAReason() {
        let cli = Options()
        CLISentryRuntimePolicy().configure(cli)
        let app = Self.reporter(.watchdog).options()
        let same: [(String, KeyPath<Options, Bool>)] = [
            ("enableAppHangTracking", \.enableAppHangTracking),
            ("enableLogs", \.enableLogs),
            ("enableMetricKit", \.enableMetricKit),
        ]
        for (name, path) in same {
            #expect(app[keyPath: path] == cli[keyPath: path], "\(name)")
        }
        // Kept: sessions give crash-free rates (release health), which a CLI run has no lifecycle for.
        #expect(app.enableAutoSessionTracking && !cli.enableAutoSessionTracking)
        // Not compared: enableWatchdogTerminationTracking installs only on UIKit platforms, and shutdownTimeInterval
        // bounds SentrySDK.close, which the app never calls.
    }

    private static let policy = CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])

    private static func reporter(_ hangTracking: CrashReporter.HangTracking) -> CrashReporter {
        CrashReporter(policy: policy, hangTracking: hangTracking)
    }
}
