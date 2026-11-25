#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileChief

/// The question bar and the band behind it obey Reduce Motion (CMUX-280): the band always ran
/// `UIView.animate` over the bar's fade duration, which the bar passed even with Reduce Motion on.
@MainActor @Suite struct ChiefQuestionBarMotionTests {
    @Test func theBarAsksForNoFadeUnderReduceMotion() {
        #expect(ChiefQuestionBar.bandFadeDuration(reduceMotion: true) == 0)
        #expect(ChiefQuestionBar.bandFadeDuration(reduceMotion: false) == ChiefQuestionBar.fadeDuration)
    }

    @Test func theBandChangesAtOnceUnderReduceMotion() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let band = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(band)
        window.isHidden = false
        defer { window.isHidden = true }
        band.alpha = 0

        // Reduce Motion on, though the bar still passed its fade.
        ChiefConversationContainer.fadeBand(band, out: false, duration: ChiefQuestionBar.fadeDuration, reduceMotion: true)
        #expect(band.alpha == 1)
        #expect(band.layer.animationKeys()?.isEmpty ?? true, "the band animated under Reduce Motion")

        ChiefConversationContainer.fadeBand(band, out: true, duration: 0, reduceMotion: false)
        #expect(band.alpha == 0)
        #expect(band.layer.animationKeys()?.isEmpty ?? true, "a zero fade still animated")

        // Without Reduce Motion it fades.
        ChiefConversationContainer.fadeBand(band, out: false, duration: ChiefQuestionBar.fadeDuration, reduceMotion: false)
        #expect(band.layer.animationKeys()?.isEmpty == false)
    }
}
#endif
