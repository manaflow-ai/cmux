#if os(iOS)
import CoreGraphics
import Testing
import UIKit
@testable import CmuxMobileScreenSharing

/// Away from a Mac's screen the app is portrait on a phone's screen and turns
/// on an unfolded foldable's ("iPhone Duo"), which people hold either way.
@Suite struct ScreenSharingOrientationTests {
    @Test func everyIPhoneScreenStaysPortraitHoweverItIsHeld() {
        // iPhone SE, 17, 17 Pro Max, in both orientations.
        for size in [CGSize(width: 375, height: 667), CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            #expect(ScreenSharingOrientation.resting(windowSize: size) == .portrait)
            #expect(ScreenSharingOrientation.resting(windowSize: CGSize(width: size.height, height: size.width)) == .portrait)
        }
    }

    @Test func anUnfoldedFoldableTurnsInEitherOrientation() {
        // The inner screen measured on a device: 669 × 951 pt portrait, 951 × 669 pt landscape.
        #expect(ScreenSharingOrientation.resting(windowSize: CGSize(width: 669, height: 951)) == .allButUpsideDown)
        #expect(ScreenSharingOrientation.resting(windowSize: CGSize(width: 951, height: 669)) == .allButUpsideDown)
    }

    @Test func noWindowYetIsPortrait() {
        #expect(ScreenSharingOrientation.resting(windowSize: .zero) == .portrait)
    }
}
#endif
