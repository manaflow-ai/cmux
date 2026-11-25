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

    /// Leo, 2026-11-23: "why do we not have a horizontal mode?" A terminal
    /// page turns with the phone on every iPhone screen.
    @Test func aTerminalPageTurnsOnEveryIPhoneScreen() {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 402, height: 874), CGSize(width: 956, height: 440)] {
            #expect(ScreenSharingOrientation.resting(windowSize: size, showingTerminal: true) == .allButUpsideDown)
        }
    }

    @Test func noWindowYetIsPortrait() {
        #expect(ScreenSharingOrientation.resting(windowSize: .zero) == .portrait)
    }

    /// UIKit calls a refused geometry request's error handler on a background queue. A handler
    /// isolated to the main actor traps there (step aed9d983: three crashes in
    /// `ScreenSharingOrientation.update()`); this one runs on a background queue and returns.
    @Test func aRefusedPortraitRequestsHandlerRunsOffTheMainQueue() async {
        let handler = ScreenSharingOrientation.ignoreGeometryError
        let ran: Bool = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .default).async {
                handler(NSError(domain: "UISceneErrorDomain", code: 100))
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(ran, "the handler ran on the main thread, so the test proves nothing")
    }
}
#endif
