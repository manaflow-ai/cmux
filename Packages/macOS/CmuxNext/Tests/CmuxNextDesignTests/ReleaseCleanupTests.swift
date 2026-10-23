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
