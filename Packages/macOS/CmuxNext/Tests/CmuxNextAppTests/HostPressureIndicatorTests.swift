import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHostPressure
import CmuxNextWakeups
import Foundation
import Testing

/// App services whose launch features have `hostPressure` on or off (`CMUX_ENABLE_FEATURES`), as the
/// launch resolves it once; the Debug toggle `hostPressure.enabled` is read only by that launch.
@MainActor private func hostPressureServices(_ on: Bool) -> AppServices {
    let overrides = FeatureOverrides(environmentEnabled: on ? [Feature.hostPressure.name] : [])
    return AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]),
                       features: FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: overrides))
}

/// A host pressure service on a test rig's scheduler (its posted tasks run on the rig's frames), with no acpmux and a
/// memory pressure feed that never changes.
@MainActor func hostPressureTestService(_ store: TunableStore, rig: MainDeadlineRig) -> HostPressureService {
    HostPressureService(acpmux: nil, memoryPressure: { _ in (.normal, {}) }, store: store, mainWork: rig.deadlines.work,
                        work: BackgroundWork(label: "test.host-pressure"), appEvents: AppEvents(center: NotificationCenter()))
}

/// Main run loop passes (where off-main posts arrive) and the rig's frames, until `done` or 5 s.
@MainActor func hostPressureSpin(until done: () -> Bool, rig: MainDeadlineRig) {
    let end = Date(timeIntervalSinceNow: 5)
    while !done(), Date() < end {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        rig.frame()
    }
}

/// The top-row host pressure indicator (cmuxterm-hq#2995): Debug Settings forces a level with
/// sample numbers for captures, and the popover shows the load against its limit, then acpmux's
/// other reasons in its words.
@MainActor @Suite struct HostPressureIndicatorTests {
    private static func store(forcing force: HostPressureForce?, toggle: Bool? = nil) -> TunableStore {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        if let force { _ = store.set(HostPressureTunables.force.key, force.tunableValue) }
        if let toggle { _ = store.set(HostPressureTunables.enabled.key, toggle.tunableValue) }
        return store
    }

    /// An indicator whose window's node is `node` and whose window notices post on `events`; `feature` is the
    /// launch's `hostPressure` feature.
    private static func indicator(store: TunableStore, rig: MainDeadlineRig, node: VisibilityNode, events: WindowEvents? = nil,
                                  feature: Bool = true, made: @escaping (HostPressureService) -> Void = { _ in })
        -> HostPressureIndicatorView {
        HostPressureIndicatorView(services: hostPressureServices(feature), store: store,
                                  mainWork: rig.deadlines.work, nodeOf: { _ in node },
                                  eventsOf: { events ?? WindowEvents(window: $0, center: NotificationCenter()) },
                                  service: {
                                      let service = hostPressureTestService(store, rig: rig)
                                      made(service)
                                      return service
                                  }) {}
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Off, the indicator never makes the service, even with the Debug toggle turned on after launch: the
    /// toggle is the feature's launch-time override, so the code uses the value `features.list` reports.
    @Test func theFeatureShipsOffAndOffNeverMakesTheService() {
        #expect(HostPressureTunables.enabled.defaultValue == false)
        #expect(Feature.Channel.allCases.allSatisfy { !Feature.hostPressure.defaults.value(for: $0) })
        let store = Self.store(forcing: .critical, toggle: true), rig = MainDeadlineRig()
        var made = 0
        let indicator = Self.indicator(store: store, rig: rig, node: VisibilityNode(root: "window", own: .visible),
                                       feature: false) { _ in made += 1 }
        indicator.reconcile()
        #expect(!indicator.sampling.samples)
        #expect(!indicator.isSampling)
        #expect(made == 0)
        #expect(indicator.isHidden)
    }

    /// The window's node is the gate: its flips (occluded, minimized, Hide cmux) reconcile the indicator with no
    /// notice of its own, and the monitor (and its timer) stops when it leaves.
    @Test func itSamplesOnlyWhileOnAndVisible() async {
        let store = Self.store(forcing: nil), rig = MainDeadlineRig()
        let node = VisibilityNode(root: "window", own: .visible)
        var service: HostPressureService?
        let indicator = Self.indicator(store: store, rig: rig, node: node) { service = $0 }
        let window = Self.window()
        window.contentView?.addSubview(indicator)
        #expect(indicator.isSampling)
        #expect(service?.subscriberCount == 1)
        #expect(await service?.monitorIsRunning() == true)

        // Occluded, minimized or hidden: it unsubscribes and the monitor (and its timer) stops.
        node.set(.occluded)
        #expect(!indicator.isSampling)
        #expect(service?.subscriberCount == 0)
        #expect(await service?.monitorIsRunning() == false)
        node.set(.visible)
        #expect(indicator.isSampling)
        node.set(.hidden)
        #expect(!indicator.isSampling)

        // Visible again: it samples again; occluded again, it stops the same way and shows nothing.
        node.set(.visible)
        #expect(await service?.monitorIsRunning() == true)
        node.set(.occluded)
        #expect(!indicator.isSampling)
        #expect(await service?.monitorIsRunning() == false)
        #expect(indicator.isHidden)
        indicator.removeFromSuperview()
        service?.stop()
    }

    /// The window's close (a WindowEvents subscription) leaves, and the indicator stops following the window.
    @Test func theWindowsCloseStopsSampling() async {
        let store = Self.store(forcing: nil), rig = MainDeadlineRig()
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        var service: HostPressureService?
        let indicator = Self.indicator(store: store, rig: rig, node: VisibilityNode(root: "window", own: .visible), events: events) {
            service = $0
        }
        window.contentView?.addSubview(indicator)
        #expect(indicator.isSampling)
        center.post(name: NSWindow.willCloseNotification, object: window)
        hostPressureSpin(until: { !indicator.isSampling }, rig: rig)
        #expect(!indicator.isSampling)
        #expect(service?.subscriberCount == 0)
        #expect(await service?.monitorIsRunning() == false)
        indicator.removeFromSuperview()
        service?.stop()
    }

    /// A subscription released without `cancel()` unsubscribes in one posted background task.
    @Test func aSubscriptionReleasedWithoutCancelStillUnsubscribes() async {
        let rig = MainDeadlineRig()
        let service = hostPressureTestService(Self.store(forcing: nil), rig: rig)
        var subscription: HostPressureSubscription? = HostPressureSubscription(service)
        #expect(service.subscriberCount == 1)
        #expect(subscription != nil)
        subscription = nil
        #expect(service.subscriberCount == 1, "the release unsubscribed in its own turn, not as a posted task")
        hostPressureSpin(until: { service.subscriberCount == 0 }, rig: rig)
        #expect(service.subscriberCount == 0)
        #expect(await !service.monitorIsRunning())
        service.stop()
    }

    /// Joining and leaving in one main-actor turn queues a start and then a stop: the start
    /// must not run the monitor (and its timer) at all.
    @Test func aStartOvertakenByTheLastLeaveStartsNothing() async {
        let service = hostPressureTestService(Self.store(forcing: nil), rig: MainDeadlineRig())
        service.subscribe()
        service.unsubscribe()
        #expect(await !service.monitorIsRunning())
        service.subscribe()
        #expect(await service.monitorIsRunning())
        service.unsubscribe()
        #expect(await !service.monitorIsRunning())
        service.stop()
    }

    @Test func theGateIsTheFeatureAndTheWindow() {
        #expect(HostPressureSampling(enabled: true, windowVisible: true).samples)
        #expect(!HostPressureSampling(enabled: true, windowVisible: false).samples)
        #expect(!HostPressureSampling(enabled: false, windowVisible: true).samples)
    }

    @Test func aForcedLevelShowsItsSampleNumbers() {
        let service = hostPressureTestService(Self.store(forcing: .critical), rig: MainDeadlineRig())
        #expect(service.level == .critical, "the forced level applies when the service starts")
        #expect(service.verdict?.top?.count == 3)
        #expect(HostPressureTracker.level(for: HostPressureService.sample(.critical), holding: .normal) == .critical)
        #expect(HostPressureTracker.level(for: HostPressureService.sample(.warning), holding: .normal) == .warning)
        service.stop()
    }

    @Test func offFollowsTheHost() {
        let service = hostPressureTestService(Self.store(forcing: nil), rig: MainDeadlineRig())
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
@MainActor @Suite struct HostPressureBannerTests {
    @Test func eachEntryIntoCriticalStartsANewSpell() {
        let store = TunableStore(), rig = MainDeadlineRig()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let service = hostPressureTestService(store, rig: rig)
        #expect(service.criticalSpell == 0)
        func force(_ force: HostPressureForce, until done: () -> Bool) {
            _ = store.set(HostPressureTunables.force.key, force.tunableValue)
            hostPressureSpin(until: done, rig: rig)
        }
        force(.critical) { service.level == .critical }
        #expect(service.criticalSpell == 1)
        force(.warning) { service.level == .warning }
        #expect(service.criticalSpell == 1)
        force(.critical) { service.level == .critical }
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

    @Test func aForcedLevelCountsAsSeenOnlyWithTheFeatureOnAndInAWindow() {
        let store = TunableStore(), rig = MainDeadlineRig()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.critical.tunableValue)
        var made: HostPressureService?
        let occluded = VisibilityNode(root: "window", own: .occluded)
        func makeIndicator(feature: Bool) -> HostPressureIndicatorView {
            HostPressureIndicatorView(services: hostPressureServices(feature), store: store, mainWork: rig.deadlines.work,
                                      nodeOf: { _ in occluded },
                                      service: {
                                          let service = hostPressureTestService(store, rig: rig)
                                          made = service
                                          return service
                                      }) {}
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let off = makeIndicator(feature: false)
        window.contentView?.addSubview(off)
        #expect(!off.sampling.samples) // the feature is off
        off.removeFromSuperview()
        let indicator = makeIndicator(feature: true)
        window.contentView?.addSubview(indicator)
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

/// The critical banner itself, driven through its toast (Codex on #24518: no test drove it). The feature
/// `hostPressure` and Debug `hostPressure.banner` on, the level forced to critical (the sample
/// numbers, no timer read), windows that count as seen, and a toast center whose host records the
/// toast views so the test presses their close and Show Details buttons as a click does.
@MainActor @Suite(.serialized) struct HostPressureBannerToastTests {
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
        let rig = MainDeadlineRig()
        let shownNode = VisibilityNode(root: "window", own: .visible)
        let toasts: CmuxToastCenter
        let service: HostPressureService
        private(set) var windows: [(window: NSWindow, indicator: HostPressureIndicatorView)] = []

        init() {
            store.register(HostPressureTunables.all)
            store.activate(file: nil)
            _ = store.set(HostPressureTunables.banner.key, true.tunableValue)
            _ = store.set(HostPressureTunables.force.key, HostPressureForce.critical.tunableValue)
            toasts = CmuxToastCenter(host: host)
            service = hostPressureTestService(store, rig: rig)
        }

        /// A window whose indicator samples (its window's node is visible).
        func window() -> (window: NSWindow, indicator: HostPressureIndicatorView) {
            let service = service, node = shownNode
            let indicator = HostPressureIndicatorView(services: hostPressureServices(true),
                                                      store: store, mainWork: rig.deadlines.work, nodeOf: { _ in node },
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

        /// Runs the rig's frames (the observations' flushes are posted tasks) until `done`; a test
        /// whose condition never comes fails here.
        func settle(_ done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            hostPressureSpin(until: done, rig: rig)
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

    @Test func atCriticalTheBannerShowsTheReasonsAndShowDetails() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        fixture.settle { indicator.isBannerShown }
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
    @Test func aClosedBannerStaysClosedUntilTheNextCriticalSpell() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        fixture.settle { indicator.isBannerShown }
        try #require(fixture.host.view(in: window)).closeButton.performClick(nil)
        #expect(!indicator.isBannerShown)
        #expect(fixture.banner(in: window) == nil)

        // A new look re-runs the level observation (the load label shows): the banner stays closed.
        fixture.set(HostPressureTunables.style, .load)
        fixture.settle { !indicator.loadLabel.isHidden }
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        // The toggle off and on again in the same spell: still closed.
        fixture.set(HostPressureTunables.banner, false)
        fixture.set(HostPressureTunables.style, .gauge)
        fixture.settle { indicator.loadLabel.isHidden }
        fixture.set(HostPressureTunables.banner, true)
        fixture.set(HostPressureTunables.style, .load)
        fixture.settle { !indicator.loadLabel.isHidden }
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)

        // Down to warning and back up: a new critical spell, so the banner shows again.
        fixture.set(HostPressureTunables.force, .warning)
        fixture.settle { indicator.level == .warning }
        #expect(fixture.service.criticalSpell == 1)
        fixture.set(HostPressureTunables.force, .critical)
        fixture.settle { indicator.isBannerShown }
        #expect(fixture.service.criticalSpell == 2)
        #expect(indicator.isBannerShown && fixture.banner(in: window) != nil)
    }

    /// Falling below critical ends the banner in code, which is not a close: the next spell shows it.
    @Test func theLevelFallingEndsTheBannerWithoutClosingIt() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        fixture.settle { indicator.isBannerShown }
        fixture.set(HostPressureTunables.force, .warning)
        fixture.settle { !indicator.isBannerShown }
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        #expect(!indicator.isHidden, "the warning glyph still shows")
        fixture.set(HostPressureTunables.force, .critical)
        fixture.settle { indicator.isBannerShown }
        #expect(fixture.banner(in: window) != nil)
    }

    /// Each window remembers its own close (`HostPressureIndicatorView.closedSpell`): closing one
    /// window's banner, or its Show Details, leaves the other window's banner up.
    @Test func eachWindowKeepsItsOwnBannerClosed() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (first, firstIndicator) = fixture.window()
        let (second, secondIndicator) = fixture.window()
        fixture.settle { firstIndicator.isBannerShown && secondIndicator.isBannerShown }
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
        fixture.settle { !firstIndicator.loadLabel.isHidden && !secondIndicator.loadLabel.isHidden }
        #expect(!firstIndicator.isBannerShown && !secondIndicator.isBannerShown)

        // The next spell shows both again.
        fixture.set(HostPressureTunables.force, .warning)
        fixture.settle { firstIndicator.level == .warning && secondIndicator.level == .warning }
        fixture.set(HostPressureTunables.force, .critical)
        fixture.settle { firstIndicator.isBannerShown && secondIndicator.isBannerShown }
        #expect(fixture.banner(in: first) != nil && fixture.banner(in: second) != nil)
    }

    /// Show Details opens the popover under the window's indicator (a popup shows only in a visible
    /// window on a screen).
    @Test(.enabled("needs a screen: a popup shows only on one") { await MainActor.run { NSScreen.main != nil } })
    func showDetailsOpensThePopover() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (window, indicator) = fixture.window()
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        fixture.settle { indicator.isBannerShown }
        #expect(!indicator.isPopoverShown)
        try #require(fixture.host.view(in: window)?.actionButton).performClick(nil)
        #expect(indicator.isPopoverShown)
        #expect(!indicator.isBannerShown && fixture.banner(in: window) == nil)
        indicator.closePopover()
    }
}
