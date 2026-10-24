import Foundation

/// How fast an agent pane's page renders, chosen when the page is made and kept for its life.
///
/// The rate never changes live: WebKit does not apply a live write of its near-60 preference to a
/// page on screen (perf-lead row 23), and in Low Power Mode it halves every page by itself.
public enum AgentPaneRenderRate: Sendable {
    /// WebKit's default: the display-rate divisor at or above 60 fps (60 on a 120 Hz display, 80 on
    /// 160 Hz). Only the debug launch variable `CMUX_NEXT_AGENT_PANE_FULL_RATE=0` asks for it.
    case capped
    /// The display's full rate, as every cmux page and browser tab.
    case full
}
