import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// cx-3wu5: the strip scrollbar's hover follows the pointer and the bar's
/// band now. A window resize or a layout change moves the band out from
/// under a still pointer: no exit arrives, and the `auto` bar must still
/// lose its hover and fade out after its idle delay.
@MainActor @Suite(.serialized)
struct StripScrollbarHoverTests {
    static func input(band: CGRect) -> StripScrollbarView.Input {
        StripScrollbarView.Input(mode: .auto, band: band, offset: 0, contentWidth: 1200, viewportWidth: 400, snaps: [])
    }

    @Test func theBandMovingAwayFromAStillPointerEndsTheHoverAndTheBarFades() async throws {
        let clock = ManualClock()
        let bar = StripScrollbarView(hideClock: clock)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        window.contentView.addSubview(bar)
        bar.update(Self.input(band: CGRect(x: 0, y: 0, width: 400, height: StripScrollbarView.bandHeight)), scrolled: true)
        #expect(bar.isShown)

        // The pointer rests on the band; the enter reaches the tracking area's owner.
        let windowPoint = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
        PointerHover.setDebugPointer(windowPoint, in: window)
        bar.updateTrackingAreas()
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        for area in bar.trackingAreas {
            if let hover = area.owner as? PointerHover { hover.mouseEntered(with: event) } else if let owner = area.owner as? NSResponder {
                owner.mouseEntered(with: event)
            }
        }
        #expect(bar.isHovered)

        // The band moves up (the screen grew); the pointer stays.
        bar.update(Self.input(band: CGRect(x: 0, y: 300, width: 400, height: StripScrollbarView.bandHeight)), scrolled: false)
        #expect(!bar.isHovered, "the band is not under the pointer any more")

        // The idle fade-out runs again (bounded: a stuck hover never fades).
        for _ in 0..<200 where bar.isShown {
            clock.advance(by: StripScrollbarView.idleDelay * 2)
            for _ in 0..<5 { await Task.yield() }
        }
        #expect(!bar.isShown, "the auto bar fades out once nothing holds it")
    }
}
