#if os(iOS)
import QuartzCore

extension CAFrameRateRange {
    /// The rate the terminal's display links ask for: 120 Hz on a ProMotion
    /// screen (80 under pressure), the screen's own rate elsewhere. Without
    /// it iOS may run a link below the screen's rate to save power, so
    /// output and scrolling step at 60 on a 120 Hz iPhone. The app's
    /// Info.plist also sets `CADisableMinimumFrameDurationOnPhone`.
    static let terminal = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
}
#endif
