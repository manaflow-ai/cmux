import AppKit
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextHome
import Testing

/// Lawrence (2026-10-08): the transcript's top band (behind the avatar and
/// the name pill) was a heavy blurred band, always shown. Now it shows only
/// while the pointer is near the top of the transcript (the header plus a
/// small margin), as a light gradient of the window background that blends
/// into the background image: never above the shared legibility scrim
/// (`ThemeTokens.legibilityScrimOpacity`). Reduce Motion shows and hides it
/// at once. The avatar and the pill stay visible either way.
@MainActor @Suite(.serialized) struct HomeHeaderFadeTests {
    static func enterExit(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            trackingNumber: 0, userData: nil))
    }

    @Test func theTopFadeShowsOnlyWhileThePointerIsNearTheHeader() async throws {
        let (window, view, _) = await HomeFirstRunTests.view()
        defer { window.close() }
        let transcript = view.transcript
        let area = try #require(transcript.headerZoneTrackingArea, "no tracking area for the top zone")
        let zone = transcript.convert(area.rect, from: area.owner as? NSView ?? transcript)
        #expect(zone.width >= transcript.bounds.width - 1, "the zone spans the transcript")
        #expect(zone.height > 80 && zone.height < 120, "the zone is the 80 pt header plus a small margin")

        #expect(transcript.headerFadeOpacity == 0, "the band shows with no pointer near")
        #expect(HomeHeaderDragTests.avatar(under: view)?.isHidden == false, "the avatar hides with the band")

        let owner = try #require(area.owner as? NSResponder)
        owner.mouseEntered(with: try Self.enterExit(.mouseEntered, in: window))
        #expect(transcript.headerFadeOpacity > 0, "the band does not show with the pointer in the zone")
        #expect(transcript.headerFadeMaxAlpha > 0)
        #expect(transcript.headerFadeMaxAlpha <= ThemeTokens.legibilityScrimOpacity + 0.001,
                "the band is heavier than the shared legibility scrim")

        owner.mouseExited(with: try Self.enterExit(.mouseExited, in: window))
        #expect(transcript.headerFadeOpacity == 0, "the band stays after the pointer leaves")
        #expect(HomeHeaderDragTests.avatar(under: view)?.isHidden == false)
    }

    @Test func reduceMotionShowsTheFadeAtOnce() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (window, view, _) = await HomeFirstRunTests.view()
        defer { window.close() }
        let owner = try #require(view.transcript.headerZoneTrackingArea?.owner as? NSResponder)
        owner.mouseEntered(with: try Self.enterExit(.mouseEntered, in: window))
        #expect(view.transcript.lastHeaderFadeDuration == 0, "the band animates under Reduce Motion")
    }
}

/// Lawrence (2026-10-08, hmdm7 far shots): with the band hidden, "Chief" on
/// the name pill was hard to read over bubble text. The pill sits on its own
/// small translucent capsule (as Messages' header pill), always shown, only
/// behind the pill, never a full-width band.
@MainActor @Suite(.serialized) struct HomeHeaderPillBackingTests {
    /// The least alpha that keeps the pill's title readable over text.
    static let minimumBacking: CGFloat = 0.6

    @Test func thePillHasItsOwnTranslucentCapsuleWhileTheBandIsHidden() async throws {
        let (window, view, _) = await HomeFirstRunTests.view()
        defer { window.close() }
        #expect(view.transcript.headerFadeOpacity == 0)
        let pill = try #require(HomeHeaderDragTests.buttons(under: view).first { $0.bezelStyle == .glass && !$0.title.isEmpty })
        let pillRect = pill.convert(pill.bounds, to: nil)
        let backings = HomeTransparencyTests.backgrounds(under: view).filter { candidate in
            guard candidate !== pill, let color = candidate.layer?.backgroundColor, color.alpha >= Self.minimumBacking else { return false }
            let rect = candidate.convert(candidate.bounds, to: nil)
            return rect.insetBy(dx: -1, dy: -1).contains(pillRect) && rect.width < view.bounds.width / 2
        }
        let backing = try #require(backings.first, "no capsule behind the name pill")
        #expect(try #require(backing.layer?.backgroundColor).alpha < 1, "the capsule is opaque")
        #expect(backing.layer?.cornerRadius ?? 0 >= backing.bounds.height / 2 - 0.5, "the backing is not a capsule")
    }
}
