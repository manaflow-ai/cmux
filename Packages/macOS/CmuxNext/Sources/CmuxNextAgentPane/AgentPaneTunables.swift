public import CmuxNextDesign
import CmuxNextPages

/// The composer strip on the agent pane's composer card (webviews strip/ComposerStrip.tsx,
/// hq#1957): the folder and machine, the chat's pull requests and its running subagents in one strip
/// on the card's top edge, in one of four looks. `off` keeps the location strip and the pull request
/// bars above it. The page gets it through the theme (`AgentPaneTheme.values` `composerStrip`).
public nonisolated enum AgentPaneComposerStrip: String, Sendable, CaseIterable, TunableChoice {
    case off
    case flat
    case tab
    case gooey
    case tray

    public var tunableTitle: String {
        switch self {
        case .off: "Off (pull request bars above)"
        case .flat: "Flat bar above the card"
        case .tab: "Attached tab"
        case .gooey: "Attached tab with fillets"
        case .tray: "Tray under the card"
        }
    }
}

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

    /// The composer strip's look (``AgentPaneComposerStrip``); off until Leo picks one.
    public static let composerStrip = Tunable<AgentPaneComposerStrip>.choice(
        "agentPane.composerStrip", PageTunables.section, "Agent composer strip",
        help: "Folder, machine, pull requests and running subagents in one strip on the composer. Switches live.",
        default: .off, code: "AgentPaneTunables.composerStrip")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, composerStrip.descriptor] }
}
