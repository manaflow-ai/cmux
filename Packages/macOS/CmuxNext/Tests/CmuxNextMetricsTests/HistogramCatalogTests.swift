import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The frozen histogram catalog (task 000): names the server accepts, one owner each, and the
/// families section 3D lists.
@Suite("Histogram catalog")
struct HistogramCatalogTests {
    @Test("Names are unique")
    func namesAreUnique() {
        let names = HistogramID.allCases.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(HistogramID.allCases).count == HistogramID.allCases.count)
    }

    @Test("A cmux name is lower case, dotted and at most 64 bytes (the server's rule)", arguments: HistogramID.allCases)
    func namesMatchTheServerRule(_ id: HistogramID) {
        guard case .chromium = id else {
            #expect(id.name.range(of: "^[a-z0-9_.]{1,64}$", options: .regularExpression) != nil, "\(id.name)")
            return
        }
        #expect(id.name.hasPrefix("chromium.") && id.name.utf8.count <= 64)
    }

    @Test("Every histogram has an owner and a layout that fits its unit", arguments: HistogramID.allCases)
    func ownerAndLayout(_ id: HistogramID) {
        #expect(!"\(id.owner)".isEmpty)
        switch (id.unit, id.layout) {
        case (.enumeration, .enumeration), (.percent, .linear), (.chromium, .chromium): break
        case (.microseconds, .logLinear), (.milliseconds, .logLinear), (.kibibytes, .logLinear), (.count, .logLinear): break
        default: Issue.record("\(id.name): \(id.unit) with \(id.layout)")
        }
    }

    @Test("The section 3D families are in the catalog")
    func specFamiliesExist() {
        let names = Set(HistogramID.allCases.map(\.name))
        for required in ["key.frame.terminal", "key.echo_frame.cloud", "input.frame.ime_commit", "resize.frame",
                         "main.turn", "main.queue_delay", "main.congestion.queue.steady", "hang.over250.per_hour",
                         "hang.thread_hung.main", "action.commit.key", "action.cmd_t", "smoothness.dropped_pct.remote_stream",
                         "frame.interval", "launch.first_frame.cold", "launch.pageins", "idle.wakeups.daemon",
                         "cef.pump", "cef.helper_exit", "renderer.unresponsive_ms", "memory.renderer_kib",
                         "memory.total_kib", "memory.hidden_workspace_kib", "cpu.daemon_pct", "disk.idle_write_kib_per_min",
                         "daemon.request.terminal_io", "daemon.dispatch.queue_us", "automation.request.query",
                         "automation.main_queue_us", "automation.blocked_person", "webview.inp.home",
                         "webview.loaf_ms.home", "webview.js_errors.home", "remote.input_to_present", "runtime.busy_ms",
                         "stability.launch", "stability.child_exit.holder", "stability.renderer.content_end.webkit",
                         "stability.renderer.unresponsive.chromium", "blocking.violations",
                         "chromium.EventLatency.KeyPressed.TotalLatency"] {
            #expect(names.contains(required), "\(required)")
        }
        #expect(names.count >= 40)
    }

    @Test("The record stubs run")
    func recordRuns() {
        let metrics = Metrics(runtime: TraceRuntime(role: .app))
        metrics.record(.keyFrame(.view), 3_200)
        metrics.record(.launchFirstFrame(.warm), duration: .milliseconds(180))
        #expect(metrics.runtime.role == .app)
    }
}
