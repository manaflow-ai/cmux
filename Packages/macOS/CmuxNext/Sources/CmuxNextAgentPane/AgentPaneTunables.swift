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

    /// How wide the chat's column draws on a wide pane (cx-ncc.107, a trial before real Settings).
    /// The page gets it with the theme (`AgentPaneTheme`, `chatWidth`), again on each change.
    public static let chatWidth = Tunable<ChatWidth>.choice(
        "agent.chatWidth", PageTunables.section, "Agent chat width",
        help: "Standard: 800px. Wide: 960px. Wide blocks: code, tables and tools 1120px, prose 800px.",
        default: .standard, code: "AgentPaneTunables.chatWidth")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, chatWidth.descriptor] }

    /// The chat column choices (the page's acpmux chatWidth.ts).
    public nonisolated enum ChatWidth: String, Sendable, CaseIterable, TunableChoice {
        case standard
        case wide
        case wideBlocks

        public var tunableTitle: String {
            switch self {
            case .standard: "Standard"
            case .wide: "Wide"
            case .wideBlocks: "Wide blocks"
            }
        }
    }
}
