import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextMemory
import Foundation
import Testing

/// ``BrowserHibernation`` follows the memory coordinator through one lossy consumer registration:
/// `start()` registers and gets the current level at once, `stop()` cancels the registration at
/// once, so a level reported while it is stopped never reaches it, and `start()` after `stop()`
/// registers again with the level of that moment. No pressure subscription of its own remains. At
/// the critical limit the coordinator's release slice runs its urgent pass.
@MainActor @Suite(.serialized)
struct BrowserHibernationPressureTests {
    @Test func stopThenStartFollowsTheCoordinatorsLevel() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ManualMemoryLevelRegistry()
        let hibernation = BrowserHibernation(cache: services.cache, memory: registry, deadlines: services.mainDeadlines)
        hibernation.start()
        #expect(registry.liveCount == 1)
        registry.send(.warning)
        #expect(hibernation.pressure == .warning)

        hibernation.stop()
        #expect(registry.liveCount == 0, "stop() must cancel the registration")
        registry.send(.critical)
        #expect(hibernation.pressure == .warning, "a level reported after stop() reached the hibernation")

        hibernation.start()
        #expect(registry.liveCount == 1, "start() did not register again")
        #expect(hibernation.pressure == .critical, "start() must take the coordinator's level of that moment")
        withExtendedLifetime((services, hibernation)) {}
    }

    /// Chrome's urgent page discarding policy acts on its critical memory limit: the coordinator's
    /// release slice, a frame after the level change, runs the urgent pass, never the pressure
    /// event's turn. Critical then normal before that frame runs no pass at all.
    @Test func aCriticalLimitRunsOneUrgentPassOnTheReleaseSlice() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let slices = HeldSlices()
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let hibernation = BrowserHibernation(cache: services.cache, memory: coordinator, deadlines: services.mainDeadlines)
        hibernation.start()

        kernel.send(.critical)
        #expect(hibernation.pressure == .critical)
        #expect(hibernation.memoryLimit.isCritical)
        #expect(hibernation.urgentPasses == 0, "the urgent pass ran in the pressure event's turn")
        slices.runAll()
        #expect(hibernation.urgentPasses == 1, "the critical limit's release slice ran no urgent pass")

        kernel.send(.normal)
        kernel.send(.critical)
        kernel.send(.normal)
        slices.runAll()
        #expect(hibernation.urgentPasses == 1, "critical then normal before the slice still ran an urgent pass")
        #expect(!hibernation.memoryLimit.isCritical)
        hibernation.stop()
        withExtendedLifetime((services, pressure, coordinator)) {}
    }

    /// Keeps the coordinator's release slices until the test runs them, as the next frames would.
    final class HeldSlices: MemoryReleaseSlicer {
        private var slices: [@MainActor () -> Void] = []
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
        func runAll() {
            while !slices.isEmpty { slices.removeFirst()() }
        }
    }

    @Test func registersAsOneLossyConsumerThatPacesItself() {
        let traits = BrowserHibernation.memoryTraits
        #expect(traits.retention == .lossy)
        #expect(traits.estimatedUsage == .large)
        #expect(!traits.isManaged, "the coordinator must not scale it by a mode share")
    }
}
