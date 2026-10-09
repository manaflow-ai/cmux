@testable import CmuxNextCrashReporting
import Darwin
import Foundation
import Sentry
import Testing

/// cx-urd.58: the options cmux-next starts Sentry with, and what every
/// event goes through before it leaves the Mac.
@Suite struct CrashReporterTests {
    private let policy = CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly.nxdog66-v1", shortVersion: "1.0.0-nightly.7", build: "7",
        isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])

    @Test func optionsCarryTheReleaseEnvironmentAndExceptionReporting() {
        let options = CrashReporter(policy: policy).options()
        #expect(options.dsn == CrashReporter.dsn)
        #expect(options.environment == "nightly-next")
        #expect(options.releaseName == "cmux-next@1.0.0-nightly.7+7")
        #expect(options.dist == "7")
        #expect(options.enableUncaughtNSExceptionReporting, "NIGHTLY crashes at the throw (cx-r3q)")
        #expect(!options.sendDefaultPii)
        #expect(options.tracesSampleRate?.doubleValue == 0)
        #expect(!options.enableLogs, "no data category the main app's crash path does not send")
        #expect(options.beforeSend != nil && options.beforeBreadcrumb != nil)
    }

    @Test func onlyDevAndNightlyTurnOnExceptionCrashes() {
        func options(_ bundleID: String, debug: Bool = false) -> Options {
            CrashReporter(policy: CrashReportingPolicy(
                bundleID: bundleID, shortVersion: "1", build: "1", isDebugBuild: debug, telemetryOptIn: true,
                managedDisablesTelemetry: false, processEnvironment: [:])).options()
        }
        // The SDK registers NSApplicationCrashOnExceptions with this option.
        #expect(options("com.cmuxterm.app.debug.t", debug: true).enableUncaughtNSExceptionReporting)
        #expect(!options("com.cmuxterm.app.rc").enableUncaughtNSExceptionReporting)
        #expect(!options("com.cmuxterm.app").enableUncaughtNSExceptionReporting)
    }

    @Test func everyEventIsScrubbedLabeledAndGroupedApartFromTheMainApp() throws {
        let beforeSend = try #require(CrashReporter(policy: policy).options().beforeSend)
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: "open failed: /Users/alice/Secret Project/notes.txt")
        let sent = try #require(beforeSend(event))
        #expect(sent.message?.formatted.contains("alice") == false, "home paths are scrubbed")
        #expect(sent.fingerprint == ["cmux-next", "{{ default }}"])
        #expect(sent.tags?["app"] == "cmux-next")
        #expect(sent.tags?["channel"] == "nightly")
        #expect(sent.tags?["dev_tag"] == "nxdog66-v1")

        let custom = Event(level: .error)
        custom.fingerprint = ["terminal-host-lost"]
        #expect(try #require(beforeSend(custom)).fingerprint == ["cmux-next", "terminal-host-lost"])
    }

    @Test func scrubbingAnEventLeavesTheScopesBreadcrumbsAlone() throws {
        // Sentry fills event.breadcrumbs with the scope's own objects, which
        // concurrent captures read without a lock (Sentry sweep rank 3).
        let beforeSend = try #require(CrashReporter(policy: policy).options().beforeSend)
        let shared = Breadcrumb(level: .info, category: "file")
        shared.message = "read /Users/alice/notes.txt"
        let event = Event(level: .error)
        event.breadcrumbs = [shared]
        let sent = try #require(beforeSend(event))
        #expect(shared.message == "read /Users/alice/notes.txt", "the scope's breadcrumb is not written")
        #expect(sent.breadcrumbs?.first?.message?.contains("alice") == false, "the sent copy is scrubbed")
    }

    @Test func aPolicyThatSaysNoNeverStartsSentry() {
        let off = CrashReportingPolicy(
            bundleID: "com.cmuxterm.app.nightly", shortVersion: "1", build: "1", isDebugBuild: false,
            telemetryOptIn: false, managedDisablesTelemetry: false, processEnvironment: [:])
        let reporter = CrashReporter(policy: off)
        #expect(!reporter.start())
        #expect(!reporter.isStarted)
    }
}

/// The saved signal actions put the app's own handlers back exactly.
@Suite(.serialized) struct SignalActionsTests {
    @Test func restorePutsTheSavedHandlerBack() {
        let signal = SIGUSR2
        var original = sigaction()
        sigaction(signal, nil, &original)
        defer { sigaction(signal, &original, nil) }

        var mine = sigaction()
        mine.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&mine.sa_mask)
        sigaction(signal, &mine, nil)
        let saved = SignalActions(capturing: [signal])
        #expect(saved.hasHandler(for: signal))

        _ = Darwin.signal(signal, SIG_DFL)
        #expect(!SignalActions(capturing: [signal]).hasHandler(for: signal))
        saved.restore()
        #expect(SignalActions(capturing: [signal]).hasHandler(for: signal))
        _ = Darwin.signal(signal, SIG_IGN)
        #expect(!SignalActions(capturing: [signal]).hasHandler(for: signal), "ignore is not a handler")
    }
}
