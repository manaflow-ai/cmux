public import SwiftUI
public import CmuxNextDesignTokens

extension MotionGate {
    /// A SwiftUI animation for a fade token, ease-out, nil when fades do not
    /// animate (`withAnimation(nil)` applies at once).
    /// Asking for it counts as the animation starting (``MotionActivity``): a gated `withAnimation` asks as it
    /// changes state, and a `.animation(_:value:)` asks on each body update (more turns judged, never fewer).
    /// SwiftUI steps it outside every layer's time base: the Motion Inspector's slow motion lengthens it as it
    /// starts (``MotionInspector/startScale``, 1 when off).
    public func animation(_ token: MotionFade) -> Animation? {
        let seconds = duration(token)
        MotionActivity.began(seconds: seconds)
        return seconds > 0 ? .easeOut(duration: seconds * MotionInspector.startScale) : nil
    }
}
