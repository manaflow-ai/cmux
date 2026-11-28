import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// First launch of a newer NIGHTLY on a Mac that once rolled back (Leo, 2026-11-24: "migration from
/// my teammates to this is good. same for my computer"): the older build's skip
/// (`cmux.next.updates.skipsBuildsThrough`, 4510358014801 on Leo's Mac while 4533834483401 ran) is
/// dropped once the running build has passed it, and kept while the rollback is still in effect.
@Suite struct OutgrownRollbackSkipTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(testSuiteName: "OutgrownRollbackSkipTests.\(UUID().uuidString)")!
    }

    @Test func aSkipBelowTheRunningBuildIsDropped() {
        let defaults = Self.defaults()
        defaults.set("4510358014801", forKey: UpdaterService.skipsBuildsThroughKey)
        #expect(UpdaterService.dropOutgrownSkip(defaults: defaults, running: "4533834483401"))
        #expect(defaults.string(forKey: UpdaterService.skipsBuildsThroughKey) == nil)
    }

    @Test func aSkipAtOrAboveTheRunningBuildStays() {
        let defaults = Self.defaults()
        defaults.set("4533834483401", forKey: UpdaterService.skipsBuildsThroughKey)
        #expect(!UpdaterService.dropOutgrownSkip(defaults: defaults, running: "4533834483401"))
        #expect(!UpdaterService.dropOutgrownSkip(defaults: defaults, running: "4510358014801"))
        #expect(defaults.string(forKey: UpdaterService.skipsBuildsThroughKey) == "4533834483401")
    }

    @Test func noSkipIsANoOp() {
        let defaults = Self.defaults()
        #expect(!UpdaterService.dropOutgrownSkip(defaults: defaults, running: "4533834483401"))
    }
}
