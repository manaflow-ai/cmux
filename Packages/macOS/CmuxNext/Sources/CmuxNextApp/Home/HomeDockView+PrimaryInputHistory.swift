import AppKit

/// The docked Home forwards Up and Down to its Messages view's history; the
/// Channels page (a web page with its own keys) takes none.
extension HomeDockView: PrimaryInputHistoryTarget {
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool {
        guard mode == .messages, let messages else { return false }
        return messages.historyTakesArrowKeys(from: responder)
    }

    func recallHistory(older: Bool) -> Bool {
        guard mode == .messages else { return false }
        return messages?.recallHistory(older: older) ?? false
    }
}
