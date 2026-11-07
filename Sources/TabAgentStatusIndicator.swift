import AppKit
import Bonsplit
import SwiftUI

/// The agent state glyph a pane tab shows before its title, using the sidebar
/// compact glyph's colors and symbols (`SidebarCompactStatusGlyph`).
///
/// Per tab only the panel's own lifecycle states are read; subagent and
/// waiting work-states are workspace-keyed, so they stay a sidebar-only signal.
/// Precedence: needs input (amber dot), running (pulsing gray dot), background
/// work pending (gray hourglass). Anything else returns nil and the tab keeps
/// its unread dot, if any.
enum TabAgentStatusIndicator {
    static func resolve(_ states: [AgentHibernationLifecycleState]) -> TabStatusIndicator? {
        if states.contains(.needsInput) {
            return TabStatusIndicator(
                color: Color(nsColor: SidebarCompactStatusGlyph.needsInputColor),
                accessibilityLabel: String(localized: "tab.agentStatus.needsInput", defaultValue: "Needs input")
            )
        }
        if states.contains(.running) {
            return TabStatusIndicator(
                pulses: true,
                accessibilityLabel: String(localized: "tab.agentStatus.running", defaultValue: "Running")
            )
        }
        if states.contains(.backgroundWorkPending) {
            return TabStatusIndicator(
                symbolName: "hourglass",
                accessibilityLabel: String(
                    localized: "tab.agentStatus.waiting",
                    defaultValue: "Waiting on background work"
                )
            )
        }
        return nil
    }
}
