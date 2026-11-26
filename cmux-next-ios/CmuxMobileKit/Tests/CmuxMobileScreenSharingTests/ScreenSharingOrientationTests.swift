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

    /// Leo, 2026-11-23: "why do we not have a horizontal mode?" Every
    /// workspace tab page turns, so a swipe from the terminal to a browser or
    /// chat tab (or an address-bar edit) keeps the phone sideways; the last
    /// page leaving (zoomed out to the grid) turns it back.
    @MainActor @Test func everyTabPageTurnsWithThePhone() {
        // Its own instance: another test's pages on `shared` can't leak in.
        let orientation = ScreenSharingOrientation()
        #expect(!orientation.isShowingTurningPage)
        orientation.tabPage("browser", shows: true)
        #expect(orientation.isShowingTurningPage)
        // The swipe: the next page is on before the last one leaves.
        orientation.tabPage("chat", shows: true)
        orientation.tabPage("browser", shows: false)
        #expect(orientation.isShowingTurningPage)
        orientation.tabPage("chat", shows: false)
        #expect(!orientation.isShowingTurningPage)
    }

    /// A phone already held sideways when a turning page appears is asked to
    /// turn now; its interface mirrors the device (home button side).
    @Test func aSidewaysPhoneMapsToItsInterfaceOrientation() {
        #expect(ScreenSharingOrientation.interface(for: .landscapeLeft) == .landscapeRight)
        #expect(ScreenSharingOrientation.interface(for: .landscapeRight) == .landscapeLeft)
        #expect(ScreenSharingOrientation.interface(for: .portrait) == nil)
        #expect(ScreenSharingOrientation.interface(for: .faceUp) == nil)
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
