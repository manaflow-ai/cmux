import CmuxNextAgentCursor
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import QuartzCore

/// Browser cursors in the presence color of the agent driving them (cx-gg84):
/// a lease names its holder's terminal, and that terminal's tab presence
/// gives the color key the sidebar dot, the tab chip and the pane tag use.
/// With the presence toggle off, or a lease that names no terminal, the
/// cursor keeps its session's cmux-cua palette color. A cursor takes its
/// color when it first draws; the lease frame comes before the act's input.
@MainActor
final class AgentCursorPresenceColors {
    static let shared = AgentCursorPresenceColors()

    private struct Holder {
        var session: String
        var terminal: ResourceID
    }

    /// Per leased target, the session holding it and that session's terminal.
    private var holders: [String: Holder] = [:]

    /// One lease frame: a clear (`lease` nil) or a lease without a terminal
    /// forgets the target.
    func leaseChanged(target: String, session: String?, terminal: String?) {
        if let session, let terminal {
            holders[target] = Holder(session: session, terminal: ResourceID(rawValue: terminal))
        } else {
            holders[target] = nil
        }
    }

    /// The fill for `session`'s cursor; `enabled` is the presence toggle.
    func color(for session: String, store: DaemonStore?, enabled: Bool = SidebarTunables.presenceDots.value) -> CGColor {
        guard enabled,
              let terminal = holders.values.first(where: { $0.session == session })?.terminal,
              let tab = store?.tab(terminalResource: terminal),
              let key = SidebarMapping.shared.presenceColorKey(tab) else {
            return AgentCursorStack.sessionColor(session)
        }
        return AgentPresenceColor(key: key).color.cgColor
    }
}
