@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHostPressure
import Testing

/// The top-row host pressure indicator (cmuxterm-hq#2995): Debug Settings forces a level with
/// sample numbers for captures, and the popover shows the load against its limit, then acpmux's
/// other reasons in its words.
@MainActor @Suite struct HostPressureIndicatorTests {
    private static func store(forcing force: HostPressureForce?, enabled: Bool? = nil) -> TunableStore {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        if let force { _ = store.set(HostPressureTunables.force.key, force.tunableValue) }
        if let enabled { _ = store.set(HostPressureTunables.enabled.key, enabled.tunableValue) }
        return store
    }

    /// Whether the test's window can be seen (it stands in for occlusion and minimizing).
    private final class Visibility { var visible = true }

    private static func indicator(store: TunableStore, visibility: Visibility, made: @escaping (HostPressureService) -> Void = { _ in })
        -> HostPressureIndicatorView {
        HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"])), store: store,
                                  windowVisible: { _ in visibility.visible },
                                  service: {
                                      let service = HostPressureService(acpmux: nil, store: store)
                                      made(service)
                                      return service
                                  }) {}
    }

    @Test func theToggleShipsOffAndOffNeverMakesTheService() {
        #expect(HostPressureTunables.enabled.defaultValue == false)
        let store = Self.store(forcing: .critical)
        var made = 0
        let indicator = Self.indicator(store: store, visibility: Visibility()) { _ in made += 1 }
        indicator.reconcile()
        #expect(!indicator.sampling.samples)
        #expect(!indicator.isSampling)
        #expect(made == 0)
        #expect(indicator.isHidden)
    }

    @Test func itSamplesOnlyWhileOnAndVisible() async {
        let store = Self.store(forcing: nil, enabled: true)
        let visibility = Visibility()
        var service: HostPressureService?
        let indicator = Self.indicator(store: store, visibility: visibility) { service = $0 }
        indicator.reconcile()
        #expect(indicator.isSampling)
        #expect(service?.subscriberCount == 1)
        #expect(service?.isMonitoring == true)

        // Hidden, minimized or occluded: it unsubscribes and the monitor (and its timer) stops.
        visibility.visible = false
        indicator.reconcile()
        #expect(!indicator.isSampling)
        #expect(service?.subscriberCount == 0)
        #expect(service?.isMonitoring == false)

        // Visible again: it samples again; the toggle going off stops it the same way.
        visibility.visible = true
        indicator.reconcile()
        #expect(service?.isMonitoring == true)
        _ = store.set(HostPressureTunables.enabled.key, false.tunableValue)
        indicator.reconcile()
        #expect(!indicator.isSampling)
        #expect(service?.isMonitoring == false)
        #expect(indicator.isHidden)
        service?.stop()
    }

    @Test func aSubscriptionReleasedWithoutCancelStillUnsubscribes() async {
        let service = HostPressureService(acpmux: nil, store: Self.store(forcing: nil, enabled: true))
        var subscription: HostPressureSubscription? = HostPressureSubscription(service)
        #expect(service.subscriberCount == 1)
        #expect(subscription != nil)
        subscription = nil
        for _ in 0 ..< 50 where service.subscriberCount != 0 { await Task.yield() }
        #expect(service.subscriberCount == 0)
        #expect(!service.isMonitoring)
        service.stop()
    }

    @Test func theGateIsTheToggleAndTheWindow() {
        #expect(HostPressureSampling(enabled: true, windowVisible: true).samples)
        #expect(!HostPressureSampling(enabled: true, windowVisible: false).samples)
        #expect(!HostPressureSampling(enabled: false, windowVisible: true).samples)
        #expect(!HostPressureSampling.isVisible(nil))
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
