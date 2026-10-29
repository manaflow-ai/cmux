/// What one ``AgentPageWarmup/start(webUI:)`` did, and the launch mark it leaves for bench-startup.py.
public nonisolated enum AgentPageWarmupOutcome: Equatable, Sendable {
    /// It made its page.
    case made
    /// An agent page was made first and started WebKit itself.
    case agentPageStartedWebKit
    /// New agent pages open in Chromium, so a WebKit page would warm nothing they use.
    case agentPagesInChromium
    /// The warm-up already ran, and marked, this launch.
    case alreadyRan

    /// The launch mark (`DebugTimings.markLaunch`), one per outcome so a bench run tells them apart;
    /// nil when the warm-up already marked this launch.
    public var launchMark: String? {
        switch self {
        case .made: "launch.agent_page_warmup"
        case .agentPageStartedWebKit: "launch.agent_page_warmup_not_needed"
        case .agentPagesInChromium: "launch.agent_page_warmup_chromium"
        case .alreadyRan: nil
        }
    }
}
