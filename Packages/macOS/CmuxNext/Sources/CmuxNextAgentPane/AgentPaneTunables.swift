public import CmuxNextDesign
import CmuxNextPages

/// Debug Settings declarations of the agent pane (DEV and NIGHTLY).
public nonisolated struct AgentPaneTunables {
    public nonisolated init() {}
    /// The agent pane move (react-pages.md): host new agent tabs on the shared page host
    /// (`cmux-page://cmux.agent/`) instead of the pane's own host. Off until the move is done; this
    /// tunable goes with the old host (P5).
    public static let pageHost = Tunable<Bool>.toggle(
        "agent.pageHost", PageTunables.section, "Agent pane on the page host",
        help: "New agent tabs load cmux-page://cmux.agent/ on the shared page host.",
        default: false, code: "AgentPaneTunables.pageHost")

    /// The composer's reasoning menu draws a stepped slider from Faster to Smarter instead of its
    /// list of levels (an opt-in look, off by default). It reaches every agent page as the
    /// `composer` event's `reasoningSlider` (AgentPaneComposerSetting, webviews composerSettings.ts).
    public static let reasoningSlider = Tunable<Bool>.toggle(
        "agent.reasoningSlider", PageTunables.section, "Reasoning slider in the composer",
        help: "The composer's reasoning menu shows a slider from Faster to Smarter instead of the list of levels.",
        default: false, code: "AgentPaneTunables.reasoningSlider")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, reasoningSlider.descriptor] }
}
