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
import Testing

/// Critical memory pressure reaches evicted terminals' last frames on two paths in one turn (the
/// warm set's budget and the memory coordinator's limit, `AppServices.memoryPressureDidChange`).
/// Only the coordinator's release slice drops the stored frames, on a later frame: the warm set's
/// smaller budget bounds the frames kept from then on and frees nothing in the event's turn
/// (p07-memory-035).
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
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()), fileInput: NoFileInput())
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

        // AppServices.memoryPressureDidChange's turn: the coordinator and the warm set see critical.
        kernel.send(.critical)
        cache.setWarmBudget(.forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: .critical))
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
