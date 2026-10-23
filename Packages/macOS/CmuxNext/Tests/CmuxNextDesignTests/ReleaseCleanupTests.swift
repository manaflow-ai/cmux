import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Hover and power-state owners clean up when they are released, on any thread. Each deinit
/// used to start with `guard Thread.isMainThread else { return }` before a
/// `MainActor.assumeIsolated` block, so a release on another thread (a background task that held
/// the last reference) skipped the cleanup: a dropped hold kept its views shown, a released reveal
/// left its probe in the region, a released hover left a tracking area whose owner was freed (AppKit
/// messages it on the next enter or exit), and a released Low Power Mode observation kept its calls.
/// A released reveal also left its view and region claims in the process-wide registries on any
/// thread (the old deinit compared each entry with `self`, which every weak reference reads as nil
/// by then). Each test drops the owner on main, then on a background thread.
@MainActor
@Suite struct ReleaseCleanupTests {
    private static func view(width: CGFloat = 120, height: CGFloat = 30) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func aDroppedHoldEndsTheRevealOnAnyThread() async {
        let region = Self.view()
        let reveal = HoverReveal(region: region, tracksPointer: false)
        reveal.add(Self.view(width: 20, height: 20))
        var hold: HoverReveal.Hold? = reveal.hold()
        #expect(hold != nil && reveal.isRevealed)
        hold = nil
        #expect(!reveal.isRevealed, "a hold dropped on main kept the views shown")

        await releaseOffMain { reveal.hold() }
        #expect(!reveal.isRevealed, "a hold dropped off main kept the views shown")
    }

    @Test func aReleasedRevealTakesItsProbeOutOfTheRegionOnAnyThread() async {
        let region = Self.view()
        var reveal: HoverReveal? = HoverReveal(region: region, tracksPointer: false)
        #expect(reveal != nil && region.subviews.count == 1)
        reveal = nil
        #expect(region.subviews.isEmpty, "a reveal released on main left its probe in the region")

        let other = Self.view()
        await releaseOffMain { HoverReveal(region: other, tracksPointer: false) }
        #expect(other.subviews.isEmpty, "a reveal released off main left its probe in the region")
    }

    /// A reveal claims its region and each added view in process-wide registries, and a focus watch
    /// on each watched view. Released, it leaves no entry under those keys (one reveal per pane and
    /// per tab strip, so entries left behind grow with every pane that closes).
    @Test func aReleasedRevealLeavesNoRegistryEntryOnAnyThread() async {
        let region = Self.view()
        let button = Self.view(width: 20, height: 20)
        var reveal: HoverReveal? = Self.claiming(region, button)
        #expect(reveal != nil && HoverReveal.hasRegistryEntries(view: button, region: region))
        reveal = nil
        #expect(HoverReveal.owner(of: button) == nil && HoverReveal.owner(ofRegion: region) == nil)
        #expect(!HoverReveal.hasRegistryEntries(view: button, region: region),
                "a reveal released on main left its registry entries")

        let otherRegion = Self.view()
        let otherButton = Self.view(width: 20, height: 20)
        await releaseOffMain { Self.claiming(otherRegion, otherButton) }
        #expect(HoverReveal.owner(of: otherButton) == nil && HoverReveal.owner(ofRegion: otherRegion) == nil)
        #expect(!HoverReveal.hasRegistryEntries(view: otherButton, region: otherRegion),
                "a reveal released off main left its registry entries")
    }

    /// A reveal on `region` that owns `button` and watches focus in it.
    private static func claiming(_ region: NSView, _ button: NSView) -> HoverReveal {
        let reveal = HoverReveal(region: region, tracksPointer: false)
        reveal.add(button)
        reveal.watchFocus(in: button)
        return reveal
    }

    @Test func aReleasedHoverTakesItsTrackingAreaOffTheViewOnAnyThread() async {
        let view = Self.view()
        var hover: PointerHover? = PointerHover(view)
        #expect(hover != nil && view.trackingAreas.count == 1)
        hover = nil
        #expect(view.trackingAreas.isEmpty, "a hover released on main left its tracking area on the view")

        await releaseOffMain { PointerHover(view) }
        #expect(view.trackingAreas.isEmpty, "a hover released off main left a tracking area whose owner is freed on the view")
    }

    /// A hover's tracking area is held by exact object, not by its identity: a view that removed
    /// every area and added its own (a row's `updateTrackingAreas`) keeps that area when the hover
    /// goes. Removal by `ObjectIdentifier` took the first area at the freed area's address, which
    /// the next `NSTrackingArea` the view adds usually reuses.
    @Test func aReleasedHoverLeavesAnotherOwnersAreaOnTheView() async {
        let view = Self.view()
        let other = NSObject()
        func replaceAreas() {
            autoreleasepool { for area in view.trackingAreas { view.removeTrackingArea(area) } }
            view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: other))
        }
        var hover: PointerHover? = PointerHover(view)
        replaceAreas()
        #expect(hover != nil && view.trackingAreas.count == 1)
        hover = nil
        #expect(view.trackingAreas.map { $0.owner === other } == [true],
                "a hover released on main removed the area the view added after its own")

        await releaseOffMain {
            let hover = PointerHover(view)
            replaceAreas()
            return hover
        }
        #expect(view.trackingAreas.map { $0.owner === other } == [true],
                "a hover released off main removed the area the view added after its own")
    }

    /// A coordinator released while a card shows removes its dismissal and move monitors and gives
    /// the card's parent back its own mouse-move setting (the parent took mouse moves everywhere
    /// while the card showed; no release restored it before).
    @Test func aReleasedHoverCardCoordinatorEndsItsMonitorsOnAnyThread() async {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.acceptsMouseMovedEvents = false
        parent.orderFrontRegardless()
        defer { parent.close() }
        let source = CardSource(window: parent)

        var seen: [(monitor: LocalEventMonitor?, watch: HoverCardMoveWatch?, panel: HoverCardPanel?)] = []
        func showing() -> HoverCardCoordinator {
            let coordinator = HoverCardCoordinator()
            coordinator.appIsActive = { true }
            coordinator.register(source)
            coordinator.pin(HoverTarget(id: CardSource.id, window: parent.windowNumber, delay: .zero), from: source)
            // The panel stays with the test, so a release off main frees no window there.
            seen.append((coordinator.monitor, coordinator.moveWatch, coordinator.panel))
            return coordinator
        }

        var coordinator: HoverCardCoordinator? = showing()
        #expect(coordinator != nil && seen[0].monitor?.isInstalled == true && seen[0].watch?.monitor.isInstalled == true)
        #expect(parent.acceptsMouseMovedEvents, "a shown card's parent takes mouse moves")
        coordinator = nil
        #expect(seen[0].monitor?.isInstalled == false && seen[0].watch?.monitor.isInstalled == false,
                "a coordinator released on main left its monitors installed")
        #expect(!parent.acceptsMouseMovedEvents, "a coordinator released on main left its card's parent taking mouse moves")

        await releaseOffMain { showing() }
        #expect(seen.count == 2 && seen[1].monitor != nil && seen[1].watch != nil, "the second card did not show")
        #expect(seen[1].monitor?.isInstalled == false && seen[1].watch?.monitor.isInstalled == false,
                "a coordinator released off main left its monitors installed")
        #expect(!parent.acceptsMouseMovedEvents, "a coordinator released off main left its card's parent taking mouse moves")
    }

    /// One card target on its window, with a plain body.
    private final class CardSource: HoverCardSource {
        static let id = HoverTargetID("card")
        let window: NSWindow
        private let body = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { window.frame }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            HoverCardBody(view: body, placement: .below, themeAnchor: nil, applyTheme: {})
        }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    /// A glass backdrop feed with a frame pending takes that frame client off its scheduler when
    /// released. Off main the deinit returned early, and the client stayed active until its next
    /// tick (red unless a display-link tick lands between the release and the check).
    @Test func aReleasedGlassBackdropFeedEndsItsPendingFrameOnAnyThread() async {
        func pending() -> GlassBackdropFeed {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let feed = GlassBackdropFeed(host: host, zoom: { 1 }, images: GlassBackdropImages(), mode: { .plain }) { _ in }
            feed.setNeedsUpdate()
            return feed
        }
        // Reads the feed's frame client after the feed is gone (the client type is CmuxNextWakeups').
        func activity(of feed: GlassBackdropFeed) -> () -> Bool? {
            let client = feed.nextFrame
            return { client?.isActive }
        }
        var feed: GlassBackdropFeed? = pending()
        let onMain = feed.map(activity) ?? { nil }
        #expect(onMain() == true)
        feed = nil
        #expect(onMain() == false, "a feed released on main left its frame client active")

        var offMain: () -> Bool? = { nil }
        await releaseOffMain {
            let feed = pending()
            offMain = activity(of: feed)
            return feed
        }
        #expect(offMain() == false, "a feed released off main left its frame client active")
    }

    @Test func aReleasedLowPowerObservationStopsItsCallsOnAnyThread() async {
        let mode = LowPowerMode(enabled: false)
        var calls = 0
        var observation: LowPowerModeObservation? = mode.observe { _ in calls += 1 }
        mode.override = true
        #expect(observation != nil && calls == 1)
        observation = nil
        mode.override = false
        #expect(calls == 1, "an observation released on main kept its calls")

        await releaseOffMain { mode.observe { _ in calls += 1 } }
        mode.override = true
        #expect(calls == 1, "an observation released off main kept its calls")
    }
}
