import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing
import CmuxNextWakeups

/// Each icon picker open is one `stall.icon_picker_open` thread slice (p09-observability task 036): its begin and
/// its end are written in the open's own call, warming the picker up writes none, and a first open's catalog load
/// (off the main actor) is not in it.
@MainActor @Suite(.serialized)
struct IconPickerOpenSignpostTests {
    /// The `stall.icon_picker_open` records of a test runtime.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var phases: [TraceRuntime.Phase] {
            state.withLock { $0 }.filter { $0.name == SignpostName.stallIconPickerOpen.rawValue }.map(\.phase)
        }

        func signposter() -> Signposter {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.stall.traceBit))
            return Signposter(category: .stall, trace: runtime)
        }
    }

    /// An anchor in no window: the picker opens without showing its panel.
    private static let anchor = IconPickerService.Anchor(view: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)),
                                                         rect: NSRect(x: 10, y: 10, width: 2, height: 2))

    @Test func eachWarmOpenIsOneSliceThatEndsInItsCall() async {
        let log = RecordLog()
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        picker.stallSignposter = log.signposter()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(log.phases.isEmpty, "warming up is not an open")
        picker.pick(current: nil, target: "workspace:1", at: Self.anchor) { _ in }
        #expect(log.phases == [.begin, .end])
        // A second open cancels the first inside its own slice.
        var results: [IconPickerResult] = []
        picker.pick(current: nil, target: "workspace:2", at: Self.anchor) { results.append($0) }
        #expect(log.phases == [.begin, .end, .begin, .end])
        #expect(results.isEmpty)
    }

    @Test func aColdOpensSliceBeginsWhenTheCatalogIsIn() async {
        let log = RecordLog()
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        picker.stallSignposter = log.signposter()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.onOpened = { [weak picker] _ in
                picker?.onOpened = nil
                done.resume()
            }
            picker.pick(current: nil, target: "workspace:1", at: Self.anchor) { _ in }
            // The catalog loads off the main actor: nothing of the open has run yet.
            #expect(log.phases.isEmpty)
        }
        #expect(log.phases == [.begin, .end])
    }
}
