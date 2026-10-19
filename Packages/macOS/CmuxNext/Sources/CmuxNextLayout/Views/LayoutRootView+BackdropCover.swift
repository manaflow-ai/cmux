public import AppKit
import CmuxNextDesign

extension LayoutRootView {
    /// The docked agent chat column of the shown screen, in window coordinates; nil when there is
    /// none, or this workspace is not on screen.
    public var agentChatColumnInWindow: CGRect? {
        guard isLive, let active = model.activeScreenID, let screen = screenViews[active],
              let column = model.activeScreen?.layout.columns.first(where: { $0.dock?.role == .agentChat }),
              let entry = screen.geometry.dock.first(where: { $0.column == column.id }) else { return nil }
        return screen.convert(entry.frame, to: nil)
    }

    /// Tells the window's art where the agent chat column is when it moved, resized, came or went,
    /// so a painting keeps its subject clear of it (``WindowMaterialView/setCover(_:for:)``). Each
    /// workspace reports under its own key: a parked one clears only its own column.
    func reportAgentChatColumn() {
        let column = agentChatColumnInWindow
        guard column != reportedAgentChatColumn else { return }
        reportedAgentChatColumn = column
        WindowMaterialView.backdrop(of: window)?.setCover(column, for: "agentChat.\(ObjectIdentifier(self).hashValue)")
    }
}
