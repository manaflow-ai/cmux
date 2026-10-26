import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p09-observability task 051 on a release router: `trace.start chromium:true` begins Chromium tracing through
/// the Chromium part, `trace.stop` ends it, and each step's report is the reply's `chromium` member in the shape
/// `cmux trace record` copies from (`path`, `offset_ns`; cmux-tui cli/trace/bundle.rs).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TraceChromiumReportsTests {
    @Test func chromiumTrueReachesChromiumAndItsReportsAreTheChromiumMember() async throws {
        let chromium = FakeChromium()
        let router = Self.router(chromium)

        let started = try await router.handle(ControlRequest(id: "1", method: "trace.start", params: ["chromium": true])).get()
        #expect(chromium.steps == ["start"])
        #expect(started["chromium"]?["state"] == "recording")
        #expect(started["chromium"]?["mode"] == "in_process")
        #expect(started["chromium"]?["offset_ns"] == 7000)
        let status = try await router.handle(ControlRequest(id: "2", method: "trace.status", params: [:])).get()
        #expect(status["chromium"] == true)

        let stopped = try await router.handle(ControlRequest(id: "3", method: "trace.stop", params: [:])).get()
        #expect(chromium.steps == ["start", "stop"])
        #expect(stopped["chromium"]?["state"] == "stopped")
        #expect(stopped["chromium"]?["path"] == .string(FakeChromium.trace))
        #expect(stopped["chromium"]?["meta_path"] == .string(FakeChromium.meta))
        #expect(stopped["chromium"]?["offset_ns"] == 7000)
        #expect(stopped["chromium"]?["error_bound_ns"] == 2000)
    }

    @Test func withoutChromiumTrueChromiumIsNotTouched() async throws {
        let chromium = FakeChromium()
        let router = Self.router(chromium)
        let started = try await router.handle(ControlRequest(id: "1", method: "trace.start", params: [:])).get()
        #expect(started["chromium"] == nil)
        let stopped = try await router.handle(ControlRequest(id: "2", method: "trace.stop", params: [:])).get()
        #expect(stopped["chromium"] == nil)
        #expect(chromium.steps.isEmpty)
    }

    /// A Chromium that cannot trace, or a stop with no whole file, is reported in its member; the app's ring
    /// still stops.
    @Test func aChromiumFailureIsReportedNotFatal() async throws {
        let chromium = FakeChromium(start: ChromiumTraceReport(state: .untraced, error: "unsupported", detail: "missing_shim_symbol"))
        let router = Self.router(chromium)
        let started = try await router.handle(ControlRequest(id: "1", method: "trace.start", params: ["chromium": true])).get()
        #expect(started["chromium"]?["state"] == "untraced")
        #expect(started["chromium"]?["reason"] == "unsupported")
        #expect(started["chromium"]?["detail"] == "missing_shim_symbol")
        #expect(started["chromium"]?["path"] == nil)
        #expect(started["app"]?["state"] == "recording")
    }

    @Test func aFailedStopNamesTheErrorAndNoFile() {
        let reply = TraceChromiumReports.json(ChromiumTraceReport(state: .error, mode: "host", error: "truncated"))
        #expect(reply == ["state": "error", "mode": "host", "error": "truncated"])
    }

    // MARK: - Helpers

    static func router(_ chromium: FakeChromium) -> ControlRouter {
        let link = TraceChromiumReports(start: { await chromium.step("start") }, stop: { await chromium.step("stop") })
        let parts = TraceControlParts(app: TraceControlTests.FakeApp(), chromium: link,
                                      secureInput: TraceControlTests.FakeSecureInput(active: false))
        return TraceControlTests.router(TraceControl(parts: parts, clock: ManualClock()))
    }

    /// Chromium's side: records each step and answers its report.
    final class FakeChromium: Sendable {
        static let trace = "/state/trace/chromium-1.trace.json"
        static let meta = "/state/trace/chromium-1.meta.json"
        private let taken = Mutex<[String]>([])
        private let startReport: ChromiumTraceReport

        var steps: [String] { taken.withLock { $0 } }

        init(start: ChromiumTraceReport = ChromiumTraceReport(state: .recording, mode: "in_process", categories: "toplevel",
                                                               offsetNanos: 7000, errorBoundNanos: 2000)) {
            startReport = start
        }

        func step(_ name: String) async -> ChromiumTraceReport {
            taken.withLock { $0.append(name) }
            guard name == "stop" else { return startReport }
            return ChromiumTraceReport(state: .stopped, mode: "in_process", path: Self.trace, metaPath: Self.meta,
                                       offsetNanos: 7000, errorBoundNanos: 2000)
        }
    }
}
