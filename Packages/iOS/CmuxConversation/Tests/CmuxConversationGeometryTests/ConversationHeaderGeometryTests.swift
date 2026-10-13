import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Header frames read from MobileSMS (iOS 26.5 and 27.0 simulators) and a
/// dark-mode iPhone 17 Pro Max screenshot of real Messages (440 pt @3x).
@Suite struct ConversationHeaderGeometryTests {
    @Test func buttonsSitOnTheSystemLayoutMargin() {
        // iPhone 17 Pro (402 pt): BackButton at x 16; Pro Max (440 pt): x 20.
        #expect(ConversationHeaderGeometry.sideMargin(layoutMargin: 16) == 16)
        #expect(ConversationHeaderGeometry.sideMargin(layoutMargin: 20) == 20)
        #expect(ConversationHeaderGeometry.sideMargin(layoutMargin: 8) == 16)
    }

    @Test func nameHoldsBetweenLargeAndXXL() {
        // MobileSMS's title label, iOS 27.0 (402 pt): SF Bold 17 at XS (the
        // headline asks for 14.67), 17 at Large, 21 at AX3 (it asks for 40).
        #expect(ConversationHeaderGeometry.namePointSize(scaled: 14.67) == 17)
        #expect(ConversationHeaderGeometry.namePointSize(scaled: 17) == 17)
        #expect(ConversationHeaderGeometry.namePointSize(scaled: 40) == 21)
    }

    @Test func backCapsuleWithoutCountIsACircle() {
        #expect(ConversationHeaderGeometry.backWidth(unreadTextWidth: nil) == 44)
    }

    @Test func unreadCapsuleMatchesMessages() {
        // "379" (a 23 pt SF 12 medium label): capsule 20...106, pill 54.33...89 x 74.67...93.67.
        let width = ConversationHeaderGeometry.backWidth(unreadTextWidth: 23)
        #expect(abs(width - 86) < 0.01)
        let pill = ConversationHeaderGeometry.unreadPillFrame(textWidth: 23)
        #expect(abs(pill.minX - 34.33) < 0.01)
        #expect(abs(pill.width - 34.67) < 0.01)
        #expect(abs(pill.minY - 12.67) < 0.01)
        #expect(pill.height == 19)
    }

    @Test func singleDigitPillIsRound() {
        let pill = ConversationHeaderGeometry.unreadPillFrame(textWidth: 7)
        #expect(pill.width == pill.height)
    }
}

@Suite struct ConversationTopEdgeGeometryTests {
    @Test func darkWashPeaksAtSixtyPercent() {
        // UIKit's pocket backdrop under Messages' header: 0.85 white / 0.6 black.
        #expect(ConversationTopEdgeGeometry.stops(dark: false)[0].1 == 0.855)
        #expect(abs(ConversationTopEdgeGeometry.stops(dark: true)[0].1 - 0.60) < 0.001)
    }

    @Test func darkRampFollowsTheMeasuredSamples() {
        // MobileSMS 26.5 dark (440 pt): wash sampled from bubbles under the
        // header at y 110/130/150/170, against our header bottom at 154.
        let stops = ConversationTopEdgeGeometry.stops(dark: true)
        func wash(at offset: CGFloat) -> CGFloat {
            for (a, b) in zip(stops, stops.dropFirst()) where offset >= a.0 && offset <= b.0 {
                return a.1 + (b.1 - a.1) * (offset - a.0) / (b.0 - a.0)
            }
            return 0
        }
        #expect(abs(wash(at: 110 - 154) - 0.517) < 0.02)
        #expect(abs(wash(at: 130 - 154) - 0.357) < 0.02)
        #expect(abs(wash(at: 150 - 154) - 0.168) < 0.02)
        #expect(abs(wash(at: 170 - 154) - 0.042) < 0.02)
    }

    @Test func rampClearsBelowTheHeader() {
        let ramp = ConversationTopEdgeGeometry.ramp(height: 200, headerBottom: 154, dark: true)
        #expect(ramp.first?.location == 0)
        #expect(ramp.last?.wash == 0)
        #expect(ramp.allSatisfy { $0.wash <= 0.6 + 0.0001 })
    }
}

/// ChatKit's CKAvatarButton carries a shadow: black 30 %, radius 3, offset
/// (5, 10) under a 50 pt circle path (iOS 27.0). UIKit's zoom close morphs
/// that source shadow; without one, the details close as a frosted glass
/// card with a wide shadow, which Messages never shows.
@Suite struct ConversationHeaderAvatarShadowTests {
    @Test func avatarShadowMatchesChatKitAvatarButton() {
        let shadow = ConversationHeaderGeometry.avatarShadow
        #expect(shadow.opacity == 0.3)
        #expect(shadow.radius == 3)
        #expect(shadow.offset == CGSize(width: 5, height: 10))
        #expect(shadow.pathDiameter == 50)
    }
}

/// Messages in landscape (iOS 27.0, iPhone 17 Pro Max, conversation pane
/// x 375...956 beside the list): a 54 pt bar from y 24 (the window's safe
/// top is 0), a 44 pt avatar at 550.83, 24 and the bold name inline to its
/// right (label at 606.83, 35.83, 153 x 20.33; chevron 8.33 x 14.67 at
/// 763.83, 38.67), the pair centered in the pane, no capsule.
@Suite struct ConversationCompactHeaderGeometryTests {
    @Test func landscapeHeaderMatchesMessages27() {
        let layout = ConversationHeaderGeometry.compactLayout(
            width: 581, safeTop: 0, nameSize: CGSize(width: 153, height: 20.33), chevronSize: CGSize(width: 8.33, height: 14.67))
        #expect(layout.barTop == 24)
        #expect(layout.barHeight == 54)
        #expect(abs(layout.avatar.minX - 175.83) < 0.05)
        #expect(layout.avatar.minY == 24)
        #expect(layout.avatar.width == 44)
        #expect(abs(layout.name.minX - 231.83) < 0.05)
        #expect(abs(layout.name.minY - 35.83) < 0.05)
        #expect(abs(layout.chevron.minX - 388.83) < 0.05)
        #expect(abs(layout.chevron.minY - 38.67) < 0.05)
        // The transcript starts at the bar's bottom.
        #expect(layout.barTop + layout.barHeight == 78)
    }

    @Test func aSafeTopAboveTheBarInsetWins() {
        let layout = ConversationHeaderGeometry.compactLayout(
            width: 581, safeTop: 32, nameSize: CGSize(width: 153, height: 20.33), chevronSize: CGSize(width: 8.33, height: 14.67))
        #expect(layout.barTop == 32)
    }
}
