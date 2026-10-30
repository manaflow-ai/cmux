import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHostPressure
import CmuxNextTestSupport
import Testing

/// The top-row host pressure indicator (cmuxterm-hq#2995): Debug Settings forces a level with
/// sample numbers for captures, and the popover shows the load against its limit, then acpmux's
/// other reasons in its words.
@MainActor @Suite(.closesItsWindows) struct HostPressureIndicatorTests {
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

    private static func indicator(store: TunableStore, visibility: Visibility, notifications: NotificationCenter = NotificationCenter(),
                                  made: @escaping (HostPressureService) -> Void = { _ in })
        -> HostPressureIndicatorView {
        HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"])), store: store,
                                  notifications: notifications,
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
        #expect(await service?.monitorIsRunning() == true)

        // Hidden, minimized or occluded: it unsubscribes and the monitor (and its timer) stops.
        visibility.visible = false
        indicator.reconcile()
        #expect(!indicator.isSampling)
        #expect(service?.subscriberCount == 0)
        #expect(await service?.monitorIsRunning() == false)

        // Visible again: it samples again; the toggle going off stops it the same way.
        visibility.visible = true
        indicator.reconcile()
        #expect(await service?.monitorIsRunning() == true)
        _ = store.set(HostPressureTunables.enabled.key, false.tunableValue)
        indicator.reconcile()
        #expect(!indicator.isSampling)
        #expect(await service?.monitorIsRunning() == false)
        #expect(indicator.isHidden)
        service?.stop()
    }

    /// The real notification path: the window's occlusion change, the app's unhide and the
    /// window's close each reconcile the indicator in a window.
    @Test func windowAndAppNotificationsStartAndStopSampling() async {
        let store = Self.store(forcing: nil, enabled: true)
        let visibility = Visibility()
        var service: HostPressureService?
        let center = NotificationCenter()
        let indicator = Self.indicator(store: store, visibility: visibility, notifications: center) { service = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(indicator)
        #expect(indicator.isSampling)
        // Let the notification tasks start listening before anything is posted.
        for _ in 0 ..< 20 { await Task.yield() }

        visibility.visible = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for _ in 0 ..< 50 where indicator.isSampling { await Task.yield() }
        #expect(!indicator.isSampling)
        #expect(await service?.monitorIsRunning() == false)

        visibility.visible = true
        center.post(name: NSApplication.didUnhideNotification, object: NSApplication.shared)
        for _ in 0 ..< 50 where !indicator.isSampling { await Task.yield() }
        #expect(indicator.isSampling)

        // Hide cmux: the app's didHide stops it too.
        visibility.visible = false
        center.post(name: NSApplication.didHideNotification, object: NSApplication.shared)
        for _ in 0 ..< 50 where indicator.isSampling { await Task.yield() }
        #expect(!indicator.isSampling)
        visibility.visible = true
        center.post(name: NSApplication.didUnhideNotification, object: NSApplication.shared)
        for _ in 0 ..< 50 where !indicator.isSampling { await Task.yield() }
        #expect(indicator.isSampling)

        center.post(name: NSWindow.willCloseNotification, object: window)
        for _ in 0 ..< 50 where indicator.isSampling { await Task.yield() }
        #expect(!indicator.isSampling)
        #expect(service?.subscriberCount == 0)
        #expect(await service?.monitorIsRunning() == false)
        indicator.removeFromSuperview()
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
        #expect(await !service.monitorIsRunning())
        service.stop()
    }

    /// Joining and leaving in one main-actor turn queues a start and then a stop: the start
    /// must not run the monitor (and its timer) at all.
    @Test func aStartOvertakenByTheLastLeaveStartsNothing() async {
        let service = HostPressureService(acpmux: nil, store: Self.store(forcing: nil, enabled: true))
        service.subscribe()
        service.unsubscribe()
        #expect(await !service.monitorIsRunning())
        service.subscribe()
        #expect(await service.monitorIsRunning())
        service.unsubscribe()
        #expect(await !service.monitorIsRunning())
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

/// A closed banner stays closed for its critical spell: a new spell starts each time the shown level
/// enters critical again, and a force that leaves the shown level as it was starts none.
@MainActor @Suite(.closesItsWindows) struct HostPressureBannerTests {
    @Test func eachEntryIntoCriticalStartsANewSpell() async {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let service = HostPressureService(acpmux: nil, store: store)
        #expect(service.criticalSpell == 0)
        func force(_ force: HostPressureForce, until done: () -> Bool) async {
            _ = store.set(HostPressureTunables.force.key, force.tunableValue)
            for _ in 0 ..< 50 where !done() { await Task.yield() }
        }
        await force(.critical) { service.level == .critical }
        #expect(service.criticalSpell == 1)
        await force(.warning) { service.level == .warning }
        #expect(service.criticalSpell == 1)
        await force(.critical) { service.level == .critical }
        #expect(service.criticalSpell == 2)
        service.stop()
    }

    @Test func theBannerShipsOffByDefault() {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        #expect(HostPressureTunables.banner.value(in: store) == false)
        _ = store.set(HostPressureTunables.banner.key, true.tunableValue)
        #expect(HostPressureTunables.banner.value(in: store) == true)
    }

    @Test func aForcedLevelCountsAsSeenOnlyWithTheToggleOnAndInAWindow() {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.critical.tunableValue)
        var made: HostPressureService?
        let indicator = HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"])),
                                                  store: store, windowVisible: { _ in false },
                                                  service: {
                                                      let service = HostPressureService(acpmux: nil, store: store)
                                                      made = service
                                                      return service
                                                  }) {}
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(indicator)
        #expect(!indicator.sampling.samples) // the toggle is off
        _ = store.set(HostPressureTunables.enabled.key, true.tunableValue)
        #expect(indicator.sampling.samples) // forced: an occluded window counts as seen
        indicator.removeFromSuperview()
        #expect(!indicator.sampling.samples) // out of its window, a forced level never samples
        #expect(!indicator.isSampling)
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.off.tunableValue)
        made?.stop()
    }

    @Test func theLoadLabelReadsLoadOverLimit() {
        #expect(HostPressureIndicatorView.loadText(HostPressureService.sample(.warning)) == "9.6 / 12")
    }
}

/// The critical banner itself, driven through its toast (Codex on #24518: no test drove it). Debug
/// `hostPressure.enabled` and `hostPressure.banner` on, the level forced to critical (the sample
/// numbers, no timer read), windows that count as seen, and a toast center whose host records the
/// toast views so the test presses their close and Show Details buttons as a click does.
@MainActor @Suite(.serialized, .closesItsWindows) struct HostPressureBannerToastTests {
    /// Records each window's toast views (the center's overlay host, without an overlay).
    @MainActor private final class RecordingHost: CmuxToastHosting {
        private(set) var shown: [(view: CmuxToastView, window: NSWindow)] = []
        func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
            shown.append((toast, window))
        }
        func move(_ toast: CmuxToastView, to slot: Int) {}
        func hide(_ toast: CmuxToastView, animated: Bool) { shown.removeAll { $0.view === toast } }
        func view(in window: NSWindow) -> CmuxToastView? { shown.last { $0.window === window }?.view }
    }

    /// The app's one service shared by every window's indicator, as `HostPressureService.shared` is.
    @MainActor private final class Fixture {
        let store = TunableStore()
        let host = RecordingHost()
        let toasts: CmuxToastCenter
        let service: HostPressureService
        private(set) var windows: [(window: NSWindow, indicator: HostPressureIndicatorView)] = []

        init() {
            store.register(HostPressureTunables.all)
            store.activate(file: nil)
            for key in [HostPressureTunables.enabled.key, HostPressureTunables.banner.key] { _ = store.set(key, true.tunableValue) }
            _ = store.set(HostPressureTunables.force.key, HostPressureForce.critical.tunableValue)
            toasts = CmuxToastCenter(host: host)
            service = HostPressureService(acpmux: nil, store: store)
        }

        /// A window whose indicator samples (it counts as seen while it is in one).
        func window() -> (window: NSWindow, indicator: HostPressureIndicatorView) {
            let service = service
            let indicator = HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"])),
                                                      store: store, notifications: NotificationCenter(), windowVisible: { $0 != nil },
                                                      service: { service }, toasts: toasts) {}
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(indicator)
            windows.append((window, indicator))
            return (window, indicator)
        }

        func banner(in window: NSWindow) -> CmuxToast? {
            toasts.toasts(in: window).first { $0.id == "host-pressure.critical" }
        }

        func set<Value: TunableValueConvertible>(_ tunable: Tunable<Value>, _ value: Value) {
            _ = store.set(tunable.key, value.tunableValue)
        }

        /// Yields (no timer, no sleep) until `done`, as the observation streams deliver; a test
        /// whose condition never comes fails here.
        func settle(_ done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0 ..< 500 where !done() { await Task.yield() }
            #expect(done(), "the observation never delivered", sourceLocation: sourceLocation)
        }

        /// Leaving its window unsubscribes each indicator (and ends its banner); then the service stops.
        func tearDown() {
            set(HostPressureTunables.force, .off)
            for (window, indicator) in windows {
                indicator.removeFromSuperview()
                #expect(!indicator.isSampling && !indicator.isBannerShown)
                window.close()
            }
            #expect(service.subscriberCount == 0)
            service.stop()
        }
    }

    @Test func atCriticalTheBannerShowsTheReasonsAndShowDetails() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        await fixture.settle { indicator.isBannerShown }
        #expect(indicator.level == .critical)
        let banner = try #require(fixture.banner(in: window))
        #expect(banner.message == HostPressureStrings.banner(HostPressurePopoverView.reasons(HostPressureService.sample(.critical))
                .joined(separator: "; ")))
        #expect(banner.message.contains("146.0"))
        #expect(banner.action?.title == HostPressureStrings.showDetails)
        #expect(banner.duration == CmuxToast.untilClosed)
    }

    /// The close button ends it, and it stays closed while the critical spell lasts (another level
    /// observation, the banner toggle going off and on), and shows again in the next spell.
    @Test func aClosedBannerStaysClosedUntilTheNextCriticalSpell() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        await fixture.settle { indicator.isBannerShown }
        try #require(fixture.host.view(in: window)).closeButton.performClick(nil)
        #expect(!indicator.isBannerShown)
        #expect(fixture.banner(in: window) == nil)

        // A new look re-runs the level observation (the load label shows): the banner stays closed.
        fixture.set(HostPressureTunables.style, .load)
        await fixture.settle { !indicator.loadLabel.isHidden }
        #expect(!indicator.loadLabel.isHidden)
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        // The toggle off and on again in the same spell: still closed.
        fixture.set(HostPressureTunables.banner, false)
        fixture.set(HostPressureTunables.style, .gauge)
        await fixture.settle { indicator.loadLabel.isHidden }
        fixture.set(HostPressureTunables.banner, true)
        fixture.set(HostPressureTunables.style, .load)
        await fixture.settle { !indicator.loadLabel.isHidden }
        #expect(!indicator.loadLabel.isHidden)
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)

        // Down to warning and back up: a new critical spell, so the banner shows again.
        fixture.set(HostPressureTunables.force, .warning)
        await fixture.settle { indicator.level == .warning }
        #expect(fixture.service.criticalSpell == 1)
        fixture.set(HostPressureTunables.force, .critical)
        await fixture.settle { indicator.isBannerShown }
        #expect(fixture.service.criticalSpell == 2)
        #expect(indicator.isBannerShown && fixture.banner(in: window) != nil)
    }

    /// Falling below critical ends the banner in code, which is not a close: the next spell shows it.
    @Test func theLevelFallingEndsTheBannerWithoutClosingIt() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        await fixture.settle { indicator.isBannerShown }
        fixture.set(HostPressureTunables.force, .warning)
        await fixture.settle { !indicator.isBannerShown }
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        #expect(!indicator.isHidden, "the warning glyph still shows")
        fixture.set(HostPressureTunables.force, .critical)
        await fixture.settle { indicator.isBannerShown }
        #expect(fixture.banner(in: window) != nil)
    }

    /// Each window remembers its own close (`HostPressureIndicatorView.closedSpell`): closing one
    /// window's banner, or its Show Details, leaves the other window's banner up.
    @Test func eachWindowKeepsItsOwnBannerClosed() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (first, firstIndicator) = fixture.window()
        let (second, secondIndicator) = fixture.window()
        await fixture.settle { firstIndicator.isBannerShown && secondIndicator.isBannerShown }
        #expect(fixture.service.subscriberCount == 2)
        #expect(fixture.banner(in: first) != nil && fixture.banner(in: second) != nil)

        try #require(fixture.host.view(in: first)).closeButton.performClick(nil)
        #expect(!firstIndicator.isBannerShown && fixture.banner(in: first) == nil)
        #expect(secondIndicator.isBannerShown && fixture.banner(in: second) != nil)

        // Show Details in the second window ends its banner too, and keeps it closed for the spell.
        let details = try #require(fixture.host.view(in: second)?.actionButton)
        details.performClick(nil)
        #expect(!secondIndicator.isBannerShown && fixture.banner(in: second) == nil)
        fixture.set(HostPressureTunables.style, .load)
        await fixture.settle { !firstIndicator.loadLabel.isHidden && !secondIndicator.loadLabel.isHidden }
        #expect(!firstIndicator.isBannerShown && !secondIndicator.isBannerShown)

        // The next spell shows both again.
        fixture.set(HostPressureTunables.force, .warning)
        await fixture.settle { firstIndicator.level == .warning && secondIndicator.level == .warning }
        fixture.set(HostPressureTunables.force, .critical)
        await fixture.settle { firstIndicator.isBannerShown && secondIndicator.isBannerShown }
        #expect(fixture.banner(in: first) != nil && fixture.banner(in: second) != nil)
    }

    /// Show Details opens the popover under the window's indicator (a popup shows only in a visible
    /// window on a screen).
    @Test(.enabled("needs a screen: a popup shows only on one") { await MainActor.run { NSScreen.main != nil } })
    func showDetailsOpensThePopover() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        await fixture.settle { indicator.isBannerShown }
        #expect(!indicator.isPopoverShown)
        try #require(fixture.host.view(in: window)?.actionButton).performClick(nil)
        #expect(indicator.isPopoverShown)
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        indicator.closePopover()
    }
}
