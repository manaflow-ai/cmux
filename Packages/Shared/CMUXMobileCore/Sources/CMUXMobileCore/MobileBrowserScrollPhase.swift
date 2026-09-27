/// Gesture phase for browser scroll replay.
public enum MobileBrowserScrollPhase: String, Codable, Equatable, Sendable {
    /// Direct gesture began.
    case began
    /// Direct gesture changed.
    case changed
    /// Direct gesture ended.
    case ended
    /// Momentum scrolling began.
    case momentumBegan = "momentum_began"
    /// Momentum scrolling changed.
    case momentumChanged = "momentum_changed"
    /// Momentum scrolling ended.
    case momentumEnded = "momentum_ended"
    /// Gesture was cancelled.
    case cancelled
}
