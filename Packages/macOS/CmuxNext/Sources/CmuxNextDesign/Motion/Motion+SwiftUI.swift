public import SwiftUI
public import CmuxNextDesignTokens

extension MotionGate {
    /// A SwiftUI animation for a fade token, ease-out, nil when fades do not
    /// animate (`withAnimation(nil)` applies at once).
    /// Asking for it counts as the animation starting (``MotionActivity``): a gated `withAnimation` asks as it
    /// changes state, and a `.animation(_:value:)` asks on each body update (more turns judged, never fewer).
    public func animation(_ token: MotionFade) -> Animation? {
        let seconds = duration(token)
        MotionActivity.began(seconds: seconds)
        return seconds > 0 ? .easeOut(duration: seconds) : nil
    }
}
