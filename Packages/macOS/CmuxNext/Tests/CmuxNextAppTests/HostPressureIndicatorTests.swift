@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHostPressure
import Testing

/// The top-row host pressure indicator (cmuxterm-hq#2995): Debug Settings forces a level with
/// sample numbers for captures, and the popover shows the load against its limit, then acpmux's
/// other reasons in its words.
@MainActor @Suite struct HostPressureIndicatorTests {
    private static func store(forcing force: HostPressureForce?) -> TunableStore {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        if let force { _ = store.set(HostPressureTunables.force.key, force.tunableValue) }
        return store
    }

    @Test func aForcedLevelShowsItsSampleNumbers() async {
        let service = HostPressureService(acpmux: nil, store: Self.store(forcing: .critical))
        await Task.yield()
        for _ in 0 ..< 20 where service.level != .critical { await Task.yield() }
        #expect(service.level == .critical)
        #expect(service.verdict?.top?.count == 3)
        #expect(HostPressureTracker.level(for: HostPressureService.sample(.critical), holding: .normal) == .critical)
        #expect(HostPressureTracker.level(for: HostPressureService.sample(.warning), holding: .normal) == .warning)
        service.stop()
    }

    @Test func offFollowsTheHost() async {
        let service = HostPressureService(acpmux: nil, store: Self.store(forcing: nil))
        await Task.yield()
        #expect(service.level == .normal)
        #expect(service.verdict == nil)
        service.stop()
    }

    @Test func thePopoverLeadsWithTheLoadAgainstItsLimit() {
        let reasons = HostPressurePopoverView.reasons(HostPressureService.sample(.critical))
        #expect(reasons.count == 4)
        #expect(reasons.first?.contains("146.0") == true)
        #expect(reasons.contains("available RAM 4% < 10%"))
        #expect(!reasons.contains { $0.hasPrefix("load1 ") })
    }

    @Test func theIndicatorIsHiddenUntilALevelShows() {
        let indicator = HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))) {}
        #expect(indicator.isHidden)
        #expect(indicator.level == .normal)
    }
}
