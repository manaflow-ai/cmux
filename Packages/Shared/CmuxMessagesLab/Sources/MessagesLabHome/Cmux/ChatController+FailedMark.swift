import AppKit

/// The red "!" beside my "Not Delivered" message: a click opens Try Again and Delete, the same
/// pair as the bubble's context menu (PaneMenu), so a failed send is never stuck. Before, the
/// mark only drew: it took no click (Lawrence 2026-11-12).
extension ChatController {
    /// The menu of the mark at `p`, or nil when `p` is on no failed mark of mine.
    func failedMarkMenu(at p: CGPoint) -> NSMenu? {
        guard let hit = demo?.failedMarkHit(p), let intents, intents.canRetrySend(hit.row.ref.messageId) else { return nil }
        let id = hit.row.ref.messageId
        let menu = NSMenu()
        menu.addItem(MenuAction(title: CmuxStrings.tryAgain, symbol: "arrow.clockwise") { [weak self] in self?.intents?.retrySend(id) })
        menu.addItem(MenuAction(title: CmuxStrings.deleteFailed, symbol: "trash") { [weak self] in self?.intents?.deleteFailedSend(id) })
        return menu
    }

    /// Opens the mark's menu under the pointer; true when `p` was on a mark.
    func failedMarkClicked(at p: CGPoint) -> Bool {
        guard let menu = failedMarkMenu(at: p) else { return false }
        menu.popUp(positioning: nil, at: p, in: host)
        return true
    }
}
