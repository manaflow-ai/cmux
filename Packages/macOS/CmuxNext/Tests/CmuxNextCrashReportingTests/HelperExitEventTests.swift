import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// A Chromium helper's abnormal end is one Sentry event (type, sub type, reason, code,
/// pump state, pid; no URL or title), at most one per process type an hour, and the macOS crash report of the
/// same process carries the same `pid` tag.
@Suite struct HelperExitEventTests {
    private static let start = ContinuousClock.now

    private static func networkServiceExit(heldBack: Int = 0) -> HelperExitEvent {
        HelperExitEvent(processType: "utility", chromiumType: "utility", subType: "network.mojom.NetworkService",
                        reason: "crashed", code: 11, codeName: "SIGSEGV", pid: 4400,
                        pump: ["mode": "in_process", "work_runs": "1200", "long_work_runs": "3", "pass_p99_ms": "1.5"],
                        heldBack: heldBack)
    }

    @Test func threeRendererCrashesInAMinuteGiveOneEvent() {
        var limiter = HelperExitRateLimiter()
        let sent = [0, 20, 40].map { limiter.admit("renderer", at: Self.start + .seconds($0)) }
        #expect(sent == [0, nil, nil])
        #expect(limiter.admit("renderer", at: Self.start + .seconds(3_599)) == nil, "still inside the hour")
        #expect(limiter.admit("renderer", at: Self.start + .seconds(3_600)) == 3, "the next event counts the 3 held back")
        #expect(limiter.admit("renderer", at: Self.start + .seconds(3_601)) == nil)
    }

    @Test func eachTypeHasItsOwnHour() {
        var limiter = HelperExitRateLimiter()
        #expect(limiter.admit("renderer", at: Self.start) == 0)
        #expect(limiter.admit("gpu", at: Self.start + .seconds(1)) == 0)
        #expect(limiter.admit("utility", at: Self.start + .seconds(2)) == 0)
        #expect(limiter.admit("renderer", at: Self.start + .seconds(3)) == nil)
        #expect(limiter.admit("gpu", at: Self.start + .seconds(4)) == nil)
    }

    @Test func theEventNamesTheHelperAndGroupsByTypeAndReason() {
        let event = Self.networkServiceExit(heldBack: 2).event()
        #expect(event.level == .error)
        #expect(event.exceptions?.first?.type == "ChromiumHelperExit")
        #expect(event.exceptions?.first?.mechanism?.handled == true)
        #expect(event.tags?["helper_type"] == "utility")
        #expect(event.tags?["helper_reason"] == "crashed")
        #expect(event.tags?["helper_subtype"] == "network.mojom.NetworkService")
        #expect(event.tags?["chromium_type"] == "utility")
        #expect(event.tags?["pid"] == "4400")
        #expect(event.extra?["code"] as? Int == 11)
        #expect(event.extra?["code_name"] as? String == "SIGSEGV")
        #expect(event.extra?["held_back"] as? Int == 2)
        #expect(event.extra?["pump_mode"] as? String == "in_process")
        #expect(event.extra?["pump_work_runs"] as? String == "1200")
        #expect(event.fingerprint == ["cef_helper_exit", "utility", "crashed"], "never the pid or the code")
    }

    /// The event through the reporter's own `beforeSend` (the scrubber and the cmux-next labels): every field
    /// survives, and the sent JSON holds no URL, page title or home path.
    @Test func theScrubberKeepsEveryFieldAndTheEventHoldsNoPageContent() throws {
        let reporter = CrashReporter(policy: CrashReportingPolicy(
            bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
            telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:]))
        let beforeSend = try #require(reporter.options().beforeSend)
        let sent = try #require(beforeSend(Self.networkServiceExit().event()))
        #expect(sent.tags?["helper_type"] == "utility")
        #expect(sent.tags?["helper_subtype"] == "network.mojom.NetworkService")
        #expect(sent.tags?["pid"] == "4400")
        #expect(sent.tags?["app"] == CrashEventLabels.app)
        #expect(sent.extra?["pump_pass_p99_ms"] as? String == "1.5")
        #expect(sent.fingerprint == [CrashEventLabels.app, "cef_helper_exit", "utility", "crashed"])
        let json = String(describing: sent.serialize())
        for content in ["http", "://", "/Users/", "title"] {
            #expect(!json.contains(content), "the event carries no \(content)")
        }
    }

    @Test func theMacOSCrashReportOfAHelperTagsItsPid() throws {
        let header = #"{"app_name":"cmux NEXT Helper (Renderer)","bug_type":"309","name":"cmux NEXT Helper (Renderer)"}"#
        let body = """
        {"procName":"cmux NEXT Helper (Renderer)","pid":4400,"procPath":"/Applications/cmux NEXT.app/Contents/Frameworks/cmux NEXT Helper (Renderer).app/Contents/MacOS/cmux NEXT Helper (Renderer)",
         "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":0,
         "threads":[{"triggered":true,"frames":[{"imageOffset":16,"imageIndex":0}]}],
         "usedImages":[{"base":4294967296,"size":4096,"uuid":"3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11","name":"Chromium Embedded Framework"}]}
        """
        let report = try #require(SystemCrashReport(data: Data((header + "\n" + body).utf8)))
        #expect(report.pid == 4400)
        #expect(SystemCrashEvent(report: report).event().tags?["pid"] == Self.networkServiceExit().event().tags?["pid"])
    }
}
