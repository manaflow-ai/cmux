import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing

/// ``BrowserHibernation`` follows its injected ``MemoryPressureEvents``: `stop()` cancels the
/// subscription at once, so a level reported while it is stopped never reaches it, and `start()`
/// after `stop()` subscribes again, so the next level reaches it exactly once.
@MainActor @Suite(.serialized)
struct BrowserHibernationPressureTests {
    @Test func stopThenStartFollowsTheNextLevelOnce() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let source = ManualMemoryPressureSource()
        let hibernation = BrowserHibernation(cache: services.cache, memoryPressure: MemoryPressureEvents(source: source),
                                             lowPower: LowPowerMode(enabled: false))
        var changes: [MemoryPressureLevel] = []
        hibernation.onPressureChange = { changes.append($0) }
        hibernation.start()
        source.send(.warning)
        #expect(changes == [.warning])

        hibernation.stop()
        source.send(.critical)
        #expect(changes == [.warning], "a level reported after stop() reached the hibernation")
        #expect(hibernation.pressure == .warning)

        hibernation.start()
        source.send(.critical)
        #expect(changes == [.warning, .critical], "after stop() then start() one event must reach the hibernation once")
        #expect(hibernation.pressure == .critical)
        withExtendedLifetime((services, hibernation)) {}
    }

    /// The app may start under pressure, and the kernel sends no event for a level that does not change:
    /// `start()` reads the level now, so the hibernation (and the warm set, through `onPressureChange`) starts at it.
    @Test func startReadsTheLevelNow() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let source = ManualMemoryPressureSource()
        source.level = .warning
        let hibernation = BrowserHibernation(cache: services.cache, memoryPressure: MemoryPressureEvents(source: source),
                                             lowPower: LowPowerMode(enabled: false))
        var changes: [MemoryPressureLevel] = []
        hibernation.onPressureChange = { changes.append($0) }
        hibernation.start()
        #expect(hibernation.pressure == .warning, "started at normal while the kernel read warning")
        #expect(changes == [.warning])
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }
}
