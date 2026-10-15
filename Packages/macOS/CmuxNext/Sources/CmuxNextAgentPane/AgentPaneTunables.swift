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

    /// The composer footer's plain look (Claude Code desktop's footer): the model name muted, no
    /// brand mark or mode lock, Plan as accent text; a chip's wash only on hover, focus or an open
    /// menu. It rides the `composer` page event (`plainFooter`, composerSettings.ts); no cmux.json key.
    public static let composerPlainFooter = Tunable<Bool>.toggle(
        "agent.composerPlainFooter", PageTunables.section, "Agent composer: plain footer",
        help: "The composer's model, effort and mode chips draw as plain text until hovered, focused or open.",
        default: false, code: "AgentPaneTunables.composerPlainFooter")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, composerPlainFooter.descriptor] }
}
