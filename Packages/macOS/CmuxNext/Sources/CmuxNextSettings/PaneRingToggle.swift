public import CmuxNextDesign

/// Focus Ring (`focusRing.toggle`, `cmux settings toggle-focus-ring`) covers every pane
/// ring: the focus ring and the unread ring on a terminal or an agent chat
/// (`notifications.attention.terminals`, `.agentChats`). The person sees one ring on a pane and
/// asks for it to go (Leo 2026-11-06: "WHY DOESN'T THE COMMAND PALETTE TOGGLE FOR FOCUS RINGS
/// WORK FOR TURNING IT OFF THIS IS NOT WORKING").
@MainActor
extension DesignSettings {
    /// Whether any pane ring can draw: what the palette row reads as on.
    public var showsAnyPaneRing: Bool { focusRing.enabled || attention.drawsAnyRing }

    /// Off: no pane ring of any kind (the unread dot on the tab and the sidebar row stays). On:
    /// the focus ring; the unread rings come back from Settings, Notifications. Applies the live
    /// value and returns the cmux.json edits to write.
    public func togglePaneRings() -> [([String], JSONValue?)] {
        guard showsAnyPaneRing else {
            focusRing.enabled = true
            return [(["focusRing", "enabled"], .bool(true))]
        }
        focusRing.enabled = false
        attention.terminalRing = .none
        attention.agentChatRing = .none
        let none = JSONValue.string(FocusRingStyle.none.rawValue)
        return [(["focusRing", "enabled"], .bool(false)),
                (["notifications", "attention", "terminals"], none), (["notifications", "attention", "agentChats"], none)]
    }
}
