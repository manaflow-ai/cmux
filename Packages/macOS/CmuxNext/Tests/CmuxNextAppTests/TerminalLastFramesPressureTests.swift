import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextMemory
@testable import CmuxNextTerminal
import Foundation
import IOSurface
import CmuxNextWakeups
import Testing

/// Critical memory pressure reaches evicted terminals' last frames on two paths in one turn (the
/// warm set's budget, `WarmSetRelease`, and the memory coordinator's limit).
/// Only the coordinator's release slice drops the stored frames, on a later frame: the warm set's
/// smaller budget bounds the frames kept from then on and frees nothing in the event's turn.
@MainActor @Suite(.serialized)
struct TerminalLastFramesPressureTests {
    /// Keeps the coordinator's release slices until the test runs them, as the next frames would.
    final class HeldSlices: MemoryReleaseSlicer {
        private var slices: [@MainActor () -> Void] = []
        var count: Int { slices.count }
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
        func runAll() {
            while !slices.isEmpty { slices.removeFirst()() }
        }
    }

    private func frame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface)
    }

    @Test func criticalPressureDropsTheFramesOnTheReleaseSliceNotInTheEventsTurn() throws {
        let cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())), fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let kernel = ManualMemoryPressureSource()
        let slices = HeldSlices()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let frames = cache.lastFrames
        frames.registerMemoryConsumer(with: coordinator)
        for index in 0..<3 {
            let made = try frame()
            frames.evict("t\(index)", atOnce: false, showsOutput: true) { made }
        }
        #expect(frames.count == 3)

        // The pressure event's turn: the coordinator sees critical, and `WarmSetRelease.updateMemoryLimit`
        // brings the warm set's budget to the critical limit's 0.
        kernel.send(.critical)
        cache.warmBudgetDidChange(to: 0)
        #expect(frames.capacity == 0)
        #expect(frames.count == 3, "frames were dropped in the pressure event's turn")
        #expect(frames.report["dropped"] == nil)
        #expect(slices.count == 1)

        slices.runAll()
        #expect(frames.count == 0)
        #expect(frames.storedBytes == 0)
        #expect(frames.report["dropped_critical"] == 3)
        #expect(frames.report["dropped"] == nil, "the warm set's budget dropped frames")
        withExtendedLifetime(pressure) {}
    }
}
