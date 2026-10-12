import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// POLISH.md on the tab strip and sidebar: a hover card opens on the first frame, a lifted tab,
/// group chip or sidebar row casts the one shared popover shadow rather than a dark one, and a
/// count badge is a small-radius rect, never a capsule.
@MainActor
struct PolishCalmChromeTests {
    private let shadow = PopupStyle.standard

    @Test func aTabHoverCardShowsWithoutWaiting() {
        let policy = HoverCardPolicy()
        let metrics = TabStripMetrics.standard
        for width in [metrics.minInactiveTabWidth, metrics.maxTabWidth] {
            #expect(policy.delay(tabWidth: width, cardIsVisible: false, sinceLastHidden: nil) == .zero)
        }
    }

    @Test func aLiftedTabCastsThePopoverShadow() {
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
        cell.isLifted = true
        #expect(CGFloat(cell.backgroundLayer.shadowOpacity) <= shadow.shadowAlpha + 0.02)
        #expect(cell.backgroundLayer.shadowRadius <= shadow.shadowBlur)
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 2)
        chip.isLifted = true
        #expect(CGFloat(chip.pill.shadowOpacity) <= shadow.shadowAlpha + 0.02)
        #expect(chip.pill.shadowRadius <= shadow.shadowBlur)
    }

    @Test func aDraggedSidebarStackCastsThePopoverShadowUnderASmallBadge() {
        let lift = DragLiftView(content: NSView(), count: 12)
        lift.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        lift.layout()
        let badge = lift.badgeBackground.frame
        #expect(badge.width > badge.height)
        #expect((lift.badgeBackground.layer?.cornerRadius ?? 0) < badge.height / 2)
        lift.setLifted(true, animated: false)
        #expect(CGFloat(lift.layer?.shadowOpacity ?? 1) <= shadow.shadowAlpha + 0.02)
        #expect((lift.layer?.shadowRadius ?? .infinity) <= shadow.shadowBlur)
    }
}
