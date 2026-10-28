import CmuxSentryReporting
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// A breadcrumb costs nothing where it is recorded; it is scrubbed when an event that carries it is sent
/// (first-5s typing bench, 2026-10-28). Sentry records a URLSession breadcrumb synchronously in the thread that
/// changed the task, so the omnibar's cancel of the previous suggest request, on main in the key's turn, ran the
/// scrubber's 13 secret regexes there: 8-20 ms per address-bar key on the optimized build. Chrome keeps its
/// diagnostics and does that work off the UI thread; Sentry's scope keeps at most `maxBreadcrumbs` of them.
@Suite struct SentryBreadcrumbScrubTimingTests {
    static let secret = "token=abcdef0123456789zz"
    static let url = "https://suggest.example.com/complete?password=hunter2hunter2hunter2"

    static func breadcrumb() -> Breadcrumb {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.message = "GET \(url) \(secret)"
        crumb.data = ["url": url]
        return crumb
    }

    static let policy = CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])

    /// Recording a breadcrumb runs no scrub: the SDK keeps it as it came (its `beforeBreadcrumb`, if any, returns it
    /// unchanged), so the thread that recorded it pays nothing.
    @Test func aRecordedBreadcrumbIsKeptRawWithNoScrubWork() throws {
        let options = CrashReporter(policy: Self.policy, hangTracking: .watchdog).options()
        let crumb = Self.breadcrumb()
        let kept = options.beforeBreadcrumb.map { $0(crumb) } ?? crumb
        let recorded = try #require(kept, "a breadcrumb was dropped")
        #expect(recorded.message == "GET \(Self.url) \(Self.secret)", "the breadcrumb was scrubbed where it was recorded")
        #expect(recorded.data?["url"] as? String == Self.url)
    }

    /// The event that carries the breadcrumb leaves the Mac with it scrubbed (the reporter's own `beforeSend`).
    @Test func aSentEventCarriesItsBreadcrumbsScrubbed() throws {
        let options = CrashReporter(policy: Self.policy, hangTracking: .watchdog).options()
        let beforeSend = try #require(options.beforeSend)
        let event = Event(level: .error)
        event.breadcrumbs = [Self.breadcrumb()]
        let sent = try #require(beforeSend(event))
        let crumb = try #require(sent.breadcrumbs?.first)
        #expect(crumb.message?.contains("hunter2") == false)
        #expect(crumb.message?.contains("abcdef0123456789zz") == false)
        #expect((crumb.data?["url"] as? String)?.contains("hunter2") == false)
    }

    /// The reporter's own sends (a failure, a non-fatal guard) run `SentrySDK.capture`, so `beforeSend` and its
    /// breadcrumb scrub, on the delivery queue: called from main, the send runs off main.
    @Test @MainActor func aSendFromMainRunsOffMain() async {
        let reporter = CrashReporter(policy: Self.policy, hangTracking: .watchdog)
        let offMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Self.send(on: reporter) { done.resume(returning: $0) }
        }
        #expect(offMain, "the send ran on the main thread")
    }

    /// Calls `deliver` from the caller's thread (main here) and reports whether the send ran off main.
    private static func send(on reporter: CrashReporter, _ ranOffMain: @escaping @Sendable (Bool) -> Void) {
        reporter.deliver { ranOffMain(!Thread.isMainThread) }
    }

    /// A non-fatal guard sent from the delivery queue still carries its caller's stack (taken where it was
    /// called), with the images that hold it, and its own fingerprint.
    @Test func aNonFatalEventCarriesTheCallersStack() throws {
        let addresses = Thread.callStackReturnAddresses.map(\.uintValue)
        let event = CrashReporter.nonFatalEvent("layout loop", type: "LayoutLoop", fingerprint: ["layout-loop"], tags: [:],
                                                extra: [:], addresses: addresses)
        let frames = try #require(event.exceptions?.first?.stacktrace?.frames)
        #expect(frames.count == addresses.count)
        #expect(frames.last?.instructionAddress == MainThreadHangEvent.hex(UInt64(addresses[0])), "innermost frame last")
        #expect(event.debugMeta?.isEmpty == false)
        #expect(event.fingerprint == ["layout-loop"])
    }
}
