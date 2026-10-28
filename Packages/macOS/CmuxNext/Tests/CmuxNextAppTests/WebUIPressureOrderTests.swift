import AppKit
@testable import CmuxNextApp
import CmuxNextBrowserCore
import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextInputCoreTestSupport
import CmuxNextMemory
import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p13-webui-047 over the app's real registrations on one memory coordinator, in the order
/// `AppServices` makes them: ``WebUIHost``'s preload slot, `ChromiumWarmup`'s spare windows and
/// ``BrowserHibernation``'s urgent discard pass. Warning drops the slot and only holds the spare
/// windows; critical drops the slot and closes the untaken spare windows in the level's turn, then
/// the coordinator's next release slice runs one ranked pass. `WebUIHostPressureTests`
/// (CmuxNextPagesTests) checks the same order with stand-ins.
@MainActor @Suite(.serialized)
struct WebUIPressureOrderTests {
    /// What closed, in order.
    @MainActor final class DropLog {
        var entries: [String] = []
    }

    /// A preloaded page that records its close; it never paints, so it waits in the slot.
    @MainActor final class LoggedPage: PreloadablePage {
        let log: DropLog
        let preloadView = NSView()
        var preloadTraceID: UInt64 { 1 }

        init(log: DropLog) { self.log = log }

        func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {}
        func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) { body(nil) }
        func preloadSetVisible(_ visible: Bool) {}
        func preloadFreeze() -> Bool { true }
        func preloadThaw() {}
        func close() { log.entries.append("preload slot") }
    }

    final class Parking: PreloadParking {
        func hold(_ view: NSView, at size: NSSize) {}
    }

    /// Chromium's spare windows with one untaken window; records the warmup's spare steps.
    @MainActor final class SpareWindowEngine: ChromiumWarmupEngine {
        let log: DropLog
        var availability: BrowserEngineAvailability = .available
        var isRunning = true
        private(set) var spareWindowCount = 1
        private(set) var held = false
        var onSpareWindowNeeded: (@MainActor () -> Void)?

        init(log: DropLog) { self.log = log }

        func usedRecently(within window: TimeInterval) async -> Bool { false }
        func preload() {}
        func libraryLoadEnded() async {}
        func warmStart(reason: String) async {}
        func initializeLoaded(reason: String) -> Bool { true }
        func prepareSpareWindow(pages: Bool) -> Bool { false }
        func dropPagesSpareWindow() {}
        func holdSpareWindows(_ held: Bool) { self.held = held }

        func closeUntakenSpareWindows() {
            guard spareWindowCount > 0 else { return }
            spareWindowCount = 0
            log.entries.append("spare windows")
        }
    }

    /// Keeps the coordinator's release slices until the test runs them, as the next frames would.
    final class HeldSlices: MemoryReleaseSlicer {
        private var slices: [@MainActor () -> Void] = []
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
        func runAll() {
            while !slices.isEmpty { slices.removeFirst()() }
        }
    }

    @Test func warningDropsTheSlotThenCriticalClosesTheSpareWindowsThenOneRankedPass() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let slices = HeldSlices()
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let log = DropLog()

        let host = WebUIHost(chromium: nil, openPanel: nil, memory: coordinator, deadlines: .testing())
        let slot = PagePreloadSlot(deadlines: services.mainDeadlines)
        host.preload = slot
        let engine = SpareWindowEngine(log: log)
        let warmup = ChromiumWarmup(engine: engine, idle: services.mainDeadlines, input: FakeInputTap(), memory: coordinator,
                                    isTrackingMenu: { false }, observeMenuEnd: { _ in NSObject() })
        let hibernation = BrowserHibernation(cache: services.cache, memory: coordinator, deadlines: services.mainDeadlines)
        hibernation.start()
        let parking = Parking()
        let preloaded = slot.preload(PagePreloadSlot.Key("newTab"), size: NSSize(width: 800, height: 600), in: parking) { _ in
            LoggedPage(log: log)
        }
        #expect(preloaded && slot.count == 1)

        kernel.send(.warning)
        #expect(log.entries == ["preload slot"], "a warning closed the untaken spare windows")
        #expect(!slot.allowsPreload)
        #expect(engine.held && engine.spareWindowCount == 1)
        slices.runAll()
        #expect(hibernation.urgentPasses == 0, "warning ran the urgent discard pass")

        kernel.send(.critical)
        #expect(log.entries == ["preload slot", "spare windows"])
        #expect(hibernation.urgentPasses == 0, "the ranked pass ran in the pressure event's turn")
        slices.runAll()
        #expect(hibernation.urgentPasses == 1, "critical ran no ranked pass, or more than one")

        kernel.send(.normal)
        #expect(slot.allowsPreload)
        #expect(!engine.held)
        hibernation.stop()
        withExtendedLifetime((services, pressure, coordinator, host, warmup, parking)) {}
    }
}
