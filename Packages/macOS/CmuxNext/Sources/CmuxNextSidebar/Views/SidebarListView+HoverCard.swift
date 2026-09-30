import AppKit
import CmuxNextDesign

// The workspace hover card (title, cwd, CPU and memory).
extension SidebarListView {
    /// Shows workspace `id`'s card now (the "Show Resource Usage" action),
    /// scrolling its row into view first.
    @discardableResult
    func showHoverCard(for id: WorkspaceID) -> Bool {
        guard let window, let workspace = workspaces[id], let row = displayed.row(for: .workspace(id)) else { return false }
        scrollToVisible(frame(for: row))
        let anchor = window.convertToScreen(convert(frame(for: row), to: nil))
        hoverCard.showPinned(workspace, anchor: anchor, parent: window)
        return hoverCard.shownID == id
    }

    /// Shows the card for a hovered workspace row, hides it otherwise
    /// (group headers, section headers, drags, renames, inactive app).
    func updateHoverCard() {
        guard drag == nil, rename == nil, let window, NSApp.isActive || WindowPlacement.noActivate,
              case .workspace(let id)? = hoveredKey, let workspace = workspaces[id],
              let row = displayed.row(for: .workspace(id)) else {
            hoverCard.hide()
            return
        }
        let anchor = window.convertToScreen(convert(frame(for: row), to: nil))
        hoverCard.hover(workspace, anchor: anchor, parent: window)
    }
}
