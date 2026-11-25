import CoreGraphics
@testable import CmuxNextAgentPane

/// The window fixture AgentSideSessionPaneTests opens side chats in; RightColumnPlacementTests keeps its own copy
/// in CmuxNextAgentPanePlacementTests, which builds on Linux without this target.
@MainActor
final class RightColumnWindow {
    var chatWidth: CGFloat = 1400
    var rightWidth: CGFloat = 700
    /// The right column's panes, top to bottom, while they hold a tab.
    private var column: [String] = []
    /// Tab key to pane; the chat is in `chat`.
    var paneOf: [String: String] = ["chat": "chat"]
    var events: [String] = []
    private var panes = 0

    /// A pane already on the right of the chat (a diff, a terminal), holding tab `key`.
    func occupy(_ key: String) {
        panes += 1
        let pane = "right\(panes)"
        column.append(pane)
        paneOf[key] = pane
    }

    func close(_ key: String) { paneOf[key] = nil }

    /// The right column's panes that still hold a tab.
    var live: [String] { column.filter { pane in paneOf.values.contains(pane) } }

    var measured: RightColumnPlacement.Column {
        let live = live
        return .init(sourceWidth: chatWidth, panes: live, widths: Dictionary(uniqueKeysWithValues: live.map { ($0, rightWidth) }))
    }

    /// Opens tab `key` where `decision` says; returns the pane it lands in.
    @discardableResult
    func place(_ decision: RightColumnPlacement.Decision<String>, key: String) -> String {
        column = live
        let pane: String
        switch decision {
        case .splitRight:
            panes += 1
            pane = "right\(panes)"
            column = [pane]
            events.append("split right")
        case .splitBelow(let above):
            panes += 1
            pane = "right\(panes)"
            column.insert(pane, at: (column.firstIndex(of: above) ?? column.count - 1) + 1)
            events.append("split below \(above)")
        case .tab(let target):
            pane = target ?? "chat"
            events.append("tab in \(pane)")
        }
        paneOf[key] = pane
        return pane
    }
}
