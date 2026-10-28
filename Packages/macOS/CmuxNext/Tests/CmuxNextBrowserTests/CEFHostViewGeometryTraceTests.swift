import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// Each geometry post of a page's host view is one `cef.geometry` instant (perf-hot
/// `cef-geometry`): the fork re-places one page window there. The test records into its own trace runtime.
@MainActor @Suite struct CEFHostViewGeometryTraceTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var geometry: [TraceRuntime.StubRecord] {
            state.withLock { $0.filter { $0.name == SignpostName.cefGeometry.rawValue } }
        }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    @Test func anOcclusionChangeIsOneGeometryInstant() {
        let log = RecordLog()
        let runtime = log.runtime()
        runtime.setCategories(.all)
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.signposter = Signposter(category: .cef, mirror: SignpostMetricKitMirror(), trace: runtime)

        view.occlusionRects = [CGRect(x: 0, y: 0, width: 40, height: 30)]
        // The same rects again: nothing changed, nothing is posted.
        view.occlusionRects = [CGRect(x: 0, y: 0, width: 40, height: 30)]

        #expect(log.geometry.map(\.phase) == [.instant])
        #expect(log.geometry.first?.arg0 == 0)
    }
}
