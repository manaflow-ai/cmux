public import SwiftUI
public import CmuxNextDesignTokens

extension MotionGate {
    /// A SwiftUI animation for a fade token, ease-out, nil when fades do not
    /// animate (`withAnimation(nil)` applies at once).
    public func animation(_ token: MotionFade) -> Animation? {
        let seconds = duration(token)
        return seconds > 0 ? .easeOut(duration: seconds) : nil
    }
}
