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
