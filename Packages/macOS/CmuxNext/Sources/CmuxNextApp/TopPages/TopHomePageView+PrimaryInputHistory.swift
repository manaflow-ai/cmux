import AppKit

/// Home's list and transcript (a Home tab, the docked Home's Messages view):
/// Up and Down go to the shown conversation's message-box history from the
/// page itself or the transcript side, never from the conversation list (its
/// arrows move the selection).
extension TopHomePageView: PrimaryInputHistoryTarget {
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool {
        guard let host else { return false }
        guard let view = responder as? NSView, view === self || view.isDescendant(of: self) else { return true }
        if view === host || view.isDescendant(of: host) { return host.historyTakesArrowKeys(from: responder) }
        return !view.isDescendant(of: list) && !(view is NSText || view is NSTextField)
    }

    func recallHistory(older: Bool) -> Bool { host?.recallHistory(older: older) ?? false }
}
