public import SwiftUI

extension Motion {
    /// A SwiftUI animation for a fade token, ease-out, nil when fades do not
    /// animate (`withAnimation(nil)` applies at once).
    public static func animation(_ token: MotionFade) -> Animation? {
        let seconds = duration(token)
        return seconds > 0 ? .easeOut(duration: seconds) : nil
    }
}
