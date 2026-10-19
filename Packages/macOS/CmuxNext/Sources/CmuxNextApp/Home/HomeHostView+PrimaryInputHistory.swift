import AppKit

/// Up and Down in a Home conversation (Lawrence 2026-10-19: "Up arrow ...
/// handle unfocus as well"): from the transcript, the pane, a header button or
/// no responder (a pane-focus shortcut, a window switch), the message box takes
/// the keyboard and recalls a sent message. The box's own arrows recall
/// through its own key handling; other text inputs and a transcript text
/// selection keep theirs.
extension HomeHostView: PrimaryInputHistoryTarget {
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, view === self || view.isDescendant(of: self) else { return true }
        return transcript.primaryInputHistoryTakesArrowKeys(from: responder)
    }

    func recallHistory(older: Bool) -> Bool { transcript.recallPrimaryInputHistory(older: older) }
}
