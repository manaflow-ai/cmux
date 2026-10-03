import Foundation

/// How fast an agent pane renders.
public enum AgentPaneRenderRate: Sendable {
    /// WebKit's default: the display-rate divisor at or above 60 fps (80 Hz
    /// on a 160 Hz display).
    case capped
    /// The display's full rate.
    case full
    /// The full rate while scrolls keep up, capped while the machine is
    /// loaded (the page's adaptive pacing policy).
    case adaptive
}
