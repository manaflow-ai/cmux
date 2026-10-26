import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHibernation
import Foundation
import Testing

/// ``BrowserHibernation`` reads a frozen page's memory only behind `frozenGrowthDiscard`, at one-shot
/// deadlines that end when the page thaws (`FrozenGrowthRule`, p07-memory.md task 020).
@MainActor @Suite(.serialized)
struct BrowserHibernationFrozenGrowthTests {
    private func makeHibernation(_ services: AppServices) -> BrowserHibernation {
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(),
                                             lowPower: LowPowerMode(enabled: false))
        hibernation.measureMemory = { [:] }
        return hibernation
    }

    @Test func withTheFeatureOffAFrozenPageIsNeverRead() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = makeHibernation(services)
        hibernation.trackGrowth("a")
        #expect(hibernation.frozenGrowth.pages.isEmpty)
        #expect(!hibernation.growthDeadline.isScheduled, "the feature is off and a reading was armed")
        withExtendedLifetime((services, hibernation)) {}
    }

    @Test func aFrozenPageArmsOneDeadlineThatItsThawDrops() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.trackGrowth("a")
        #expect(hibernation.growthDeadline.isScheduled)
        #expect(hibernation.frozenGrowth.pages["a"]?.baseline == nil, "no reading was fresh at the freeze")
        hibernation.untrackGrowth("a")
        #expect(!hibernation.growthDeadline.isScheduled, "a thawed page kept its reading deadline")
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    @Test func aFreshReadingAtTheFreezeIsTheBaseline() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.memoryBytes = ["a": 100 << 20]
        hibernation.memoryMeasuredAt = .now
        hibernation.trackGrowth("a")
        #expect(hibernation.frozenGrowth.pages["a"]?.baseline == 100 << 20)
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }
}
