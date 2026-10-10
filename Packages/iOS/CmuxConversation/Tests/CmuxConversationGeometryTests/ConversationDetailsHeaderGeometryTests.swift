import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Expected values were read from MobileSMS (iOS 26.5, iPhone 17 Pro Max,
/// 440 x 956, safe top 62): CommunicationDetails' header frames at fixed
/// content offsets of the details scroll view, and the title's ink in
/// screenshots at those offsets.
struct ConversationDetailsHeaderGeometryTests {
    let safeTop: CGFloat = 62
    let width: CGFloat = 440

    func layout(_ offset: CGFloat, tabs: Bool = false, group: Bool = false) -> ConversationDetailsHeaderLayout {
        ConversationDetailsHeaderGeometry.layout(width: width, safeTop: safeTop, offset: offset, showsTabs: tabs, isGroup: group)
    }

    @Test func restingHeaderMatchesMessages() {
        let l = layout(0)
        #expect(l.avatar == CGRect(x: 180, y: 62, width: 80, height: 80))
        #expect(abs(l.titleTop - 146) < 0.01)
        #expect(l.titleScale == 1)
        #expect(l.quickActions == CGRect(x: 128, y: 195 + 2.0 / 3, width: 184, height: 48))
        #expect(l.quickActionsAlpha == 1)
        // Content starts 20 pt under the quick actions without tabs.
        #expect(abs(l.height - (263 + 2.0 / 3)) < 0.01)
    }

    @Test func tabsAddTheirBarAndPadding() {
        let l = layout(0, tabs: true)
        #expect(abs(l.tabBar.minY - (263 + 2.0 / 3)) < 0.01)
        #expect(l.tabBar.height == 34)
        #expect(abs(l.height - (317 + 2.0 / 3)) < 0.01)
    }

    @Test func collapsesLinearlyOverNinetySevenPoints() {
        // offset 10: avatar 77.94, container 143.63, actions 188.30
        let ten = layout(10)
        #expect(abs(ten.avatar.width - 77.943) < 0.01)
        #expect(abs(ten.avatar.midX - 220) < 0.001)
        #expect(abs(ten.titleTop - 143.634) < 0.01)
        #expect(abs(ten.quickActions.minY - 188.301) < 0.2)
        #expect(abs(ten.height - (253 + 2.0 / 3)) < 0.01)
        let full = layout(200)
        #expect(full.avatar == CGRect(x: 190, y: 62, width: 60, height: 60))
        #expect(abs(full.titleTop - 123) < 0.01)
        #expect(abs(full.height - 166.44) < 0.01)
        // The title's ink shrinks from 245.67 to 155 pt wide.
        #expect(abs(full.titleScale - 0.63) < 0.005)
        #expect(full.quickActionsAlpha == 0)
    }

    @Test func quickActionsFadeByAboutSixtyPoints() {
        #expect(abs(layout(29).quickActionsAlpha - 0.5) < 0.03)
        #expect(layout(60).quickActionsAlpha == 0)
    }

    @Test func pullingDownStretchesTheHeader() {
        // offset -40: avatar 85.83, container 152.70, actions 216.37, tab bar 292.0
        let l = layout(-40)
        #expect(abs(l.avatar.width - 85.83) < 0.05)
        #expect(abs(l.titleTop - 152.70) < 0.05)
        #expect(abs(l.quickActions.minY - 216.37) < 0.3)
        #expect(abs(l.tabBar.minY - 292.0) < 0.3)
    }

    @Test func groupsSitFourPointsLower() {
        // Messages' group header (user recording, iPhone 17 Pro Max): the title,
        // actions and tabs are 4.33 pt lower than a 1:1 contact's.
        let l = layout(0, tabs: true, group: true)
        #expect(abs(l.tabBar.minY - 268) < 0.01)
        #expect(abs(l.quickActions.minY - 200) < 0.01)
    }

    @Test func zoomAlignmentIsTheAvatarsSquare() {
        // UIZoomTransitionOptions.alignmentRectProvider in Messages: 208 pt
        // around the 80 pt avatar.
        let rect = ConversationDetailsHeaderGeometry.zoomAlignmentRect(width: width, safeTop: safeTop)
        #expect(rect == CGRect(x: 116, y: -2, width: 208, height: 208))
    }
}
