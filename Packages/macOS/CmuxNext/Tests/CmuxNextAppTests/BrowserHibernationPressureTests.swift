import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing

/// ``BrowserHibernation`` follows the memory coordinator through one lossy consumer registration:
/// `start()` registers and gets the current level at once, `stop()` cancels the registration at
/// once, so a level reported while it is stopped never reaches it, and `start()` after `stop()`
/// registers again with the level of that moment. No pressure subscription of its own remains.
@MainActor @Suite(.serialized)
struct BrowserHibernationPressureTests {
    @Test func stopThenStartFollowsTheCoordinatorsLevel() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ManualMemoryLevelRegistry()
        let hibernation = BrowserHibernation(cache: services.cache, memory: registry, lowPower: LowPowerMode(enabled: false))
        var changes: [MemoryPressureLevel] = []
        hibernation.onPressureChange = { changes.append($0) }
        hibernation.start()
        #expect(registry.liveCount == 1)
        registry.send(.warning)
        #expect(changes == [.warning])

        hibernation.stop()
        #expect(registry.liveCount == 0, "stop() must cancel the registration")
        registry.send(.critical)
        #expect(changes == [.warning], "a level reported after stop() reached the hibernation")
        #expect(hibernation.pressure == .warning)

        hibernation.start()
        #expect(changes == [.warning, .critical], "start() must take the coordinator's level of that moment, once")
        registry.send(.critical)
        #expect(changes == [.warning, .critical], "a repeated level must not reach the hibernation again")
        #expect(hibernation.pressure == .critical)
        withExtendedLifetime((services, hibernation)) {}
    }

    @Test func registersAsOneLossyConsumerThatPacesItself() {
        let traits = BrowserHibernation.memoryTraits
        #expect(traits.retention == .lossy)
        #expect(traits.estimatedUsage == .large)
        #expect(!traits.isManaged, "the coordinator must not scale it by a mode share")
    }
}
