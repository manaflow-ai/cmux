public import CmuxNextDesign
import CmuxNextPages

/// How the agent pane's header draws Needs you (webviews needsYou/NeedsYou.tsx):
/// `agentPane.debug.needsYou`. `pinned` sets nothing on the page.
public nonisolated enum AgentPaneNeedsYouStyle: String, Sendable, CaseIterable, TunableChoice {
    /// A badge with the count of open asks; a press opens every ask with its answers (default).
    case pinned
    /// The same list, one line per ask, with no answers in it.
    case compact
    /// No badge.
    case off

    public var tunableTitle: String {
        switch self {
        case .pinned: "Pinned list with answers (default)"
        case .compact: "Compact list, one line per ask"
        case .off: "Off"
        }
    }
}

nonisolated extension AgentPaneTunables {
    /// Needs you (Leo 2026-10-20): one pinned list of every open ask (approvals, decisions,
    /// verify-this asks, held messages) from every agent chat and the Chief, behind a badge in the
    /// chat header. Debug Settings' choice applies only while the App Store item is installed
    /// (``needsYouInstalled``). New agent tabs read it.
    public static let needsYou = Tunable<AgentPaneNeedsYouStyle>.choice(
        "agentPane.debug.needsYou", PageTunables.section, "Needs you list in the chat header",
        help: "A badge in the agent chat header counts every open ask; a press lists them with one-click answers, Go to source and Ask about this. New agent tabs.",
        default: .pinned, code: "AgentPaneTunables.needsYou")

    /// Whether Needs you is installed: `agentPane.needsYou.enabled`, an App Store item, off by
    /// default (Leo 2026-10-22). The App reads it from cmux.json (AgentPanePageSettings); a host
    /// with no settings reads off. New agent tabs read it with ``needsYou``.
    @MainActor public static var needsYouInstalled: @MainActor () -> Bool = { false }

    /// The Needs you style a new agent page gets: ``needsYou``'s while the item is installed,
    /// `.off` (no badge, no list) while it is not.
    static func needsYouStyle(installed: Bool, debug: AgentPaneNeedsYouStyle) -> AgentPaneNeedsYouStyle {
        installed ? debug : .off
    }

    /// While an ask is open, Jump to latest becomes a "Needs your input" pill that goes to the ask
    /// and cycles through the others (Claude Code desktop's, Leo 2026-10-20). Off by default (Leo
    /// 2026-10-23: "default off for needs your input.. bc it doenstr work rn... we need to fix it");
    /// off keeps the plain button. New agent tabs read it.
    public static let needsYouPill = Tunable<Bool>.toggle(
        "agentPane.debug.needsYouPill", PageTunables.section, "Needs your input pill",
        help: "While an agent waits on you, the floating Jump to latest button reads Needs your input and goes to the ask. New agent tabs.",
        default: false, code: "AgentPaneTunables.needsYouPill")
}
