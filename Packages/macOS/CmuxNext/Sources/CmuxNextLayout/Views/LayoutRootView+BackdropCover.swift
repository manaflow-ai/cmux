public import AppKit

extension LayoutRootView {
    /// Posted, with this root as the object, when ``agentChatColumnInWindow`` changes: the window's
    /// art keeps its subject clear of that column (``BackdropVisibleSpan``).
    public static let agentChatColumnDidChange = Notification.Name("LayoutRootView.agentChatColumnDidChange")

    /// The docked agent chat column of the shown screen, in window coordinates; nil when there is
    /// none, or this workspace is not on screen.
    public var agentChatColumnInWindow: CGRect? {
        guard isLive, let active = model.activeScreenID, let screen = screenViews[active],
              let column = model.activeScreen?.layout.columns.first(where: { $0.dock?.role == .agentChat }),
              let entry = screen.geometry.dock.first(where: { $0.column == column.id }) else { return nil }
        return screen.convert(entry.frame, to: nil)
    }

    /// Posts ``agentChatColumnDidChange`` when the column moved, resized, came or went.
    func reportAgentChatColumn() {
        let column = agentChatColumnInWindow
        guard column != reportedAgentChatColumn else { return }
        reportedAgentChatColumn = column
        NotificationCenter.default.post(name: Self.agentChatColumnDidChange, object: self)
    }
}
