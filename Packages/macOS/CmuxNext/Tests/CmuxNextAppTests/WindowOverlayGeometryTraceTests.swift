import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// A parent window's geometry change is one `cef.geometry` slice (perf-hot `cef-geometry`):
/// the catcher sync inside it takes no slice of its own, and a change reported inside the window's layout pass
/// writes its slice once the pass ends. The overlay layer records into the test's own trace runtime.
@MainActor @Suite(.serialized) struct WindowOverlayGeometryTraceTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var geometry: [TraceRuntime.StubRecord] {
            state.withLock { $0.filter { $0.name == SignpostName.cefGeometry.rawValue } }
        }

        func clear() { state.withLock { $0.removeAll() } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    private struct Rig {
        let log = RecordLog()
        let window: NSWindow
        let layer: WindowOverlayLayer

        init() {
            _ = NSApplication.shared
            let runtime = log.runtime()
            runtime.setCategories(.all)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            layer = WindowOverlayLayer(window: window,
                                       signposter: Signposter(category: .cef, mirror: SignpostMetricKitMirror(), trace: runtime),
                                       currentTurn: { 0 })
            log.clear()
        }

        /// A real resize (wider, same origin, so no move): AppKit posts the window's didResize itself.
        func resize() {
            var frame = window.frame
            frame.size.width += 40
            window.setFrame(frame, display: false)
        }

        func close() {
            layer.teardown()
            window.close()
        }
    }

    @Test func aParentResizeIsOneSliceWithNoNestedCatcherSlice() {
        let rig = Rig()
        defer { rig.close() }

        rig.resize()

        let records = rig.log.geometry
        #expect(records.map(\.phase) == [.begin, .end], "\(records)")
        #expect(records.first?.arg0 == Signposter.CEFGeometrySource.parentGeometry.rawValue)
        #expect(records.last?.arg0 == 0, "no page shows, so no catcher panel shows")
        #expect(records.last?.arg1 == 0, "no catcher panel was made or moved")
    }

    @Test func aResizeInsideTheLayoutPassWritesItsSliceWhenThePassEnds() {
        let rig = Rig()
        defer { rig.close() }

        rig.layer.windowWillLayout()
        rig.resize()
        #expect(rig.log.geometry.isEmpty, "the slice waits for the layout pass to end")

        rig.layer.windowDidLayout()
        let records = rig.log.geometry
        #expect(records.map(\.phase) == [.begin, .end], "\(records)")
        #expect(records.first?.arg0 == Signposter.CEFGeometrySource.parentGeometry.rawValue)
    }
}
