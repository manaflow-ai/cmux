public import AppKit
public import CmuxNextDesign

/// A toast never covers the chat (Leo, 2026-11-06: "why is this still happening yo", a machine
/// toast drawn over his own message). Toasts rest above the message box (``CmuxToastAvoiding``);
/// the transcript keeps its newest message above them, sliding up as one shows or grows with its
/// Details and back down as it goes, in the toasts' own motion.
extension HomeNativeTranscriptView: CmuxToastReserving {
    public func toastsSettled(in rect: NSRect?, duration: TimeInterval) {
        toastsRect = rect
        transcript.setRowsBottomClearance(toastClearance(for: rect), duration: duration)
    }

    /// The view was laid out (a resize, a move in its window, the field grew): the room follows at once.
    func followToasts() {
        guard toastsRect != nil || transcript.rowsBottomClearance != 0 else { return }
        transcript.setRowsBottomClearance(toastClearance(for: toastsRect), duration: 0)
    }

    /// The room the transcript keeps under its newest message for toasts in `rect` (window
    /// coordinates): from where the rows end at rest up to the toasts' top and a gap, when the toasts
    /// lie over the transcript.
    func toastClearance(for rect: NSRect?) -> CGFloat {
        guard let rect, window != nil, !rect.isEmpty else { return 0 }
        let local = convert(rect, from: nil)
        let place = transcript.frame
        guard local.maxX > place.minX, local.minX < place.maxX else { return 0 }
        let rowsBottom = place.minY + transcript.restingRowsBottom
        // Never past the header: the newest message keeps some room to show in a short pane.
        let most = max(0, rowsBottom - place.minY - transcript.headerHeight)
        return min(most, max(0, rowsBottom - local.minY + Self.toastRowsGap))
    }

    /// The gap between the toasts' top and the newest row above them.
    static let toastRowsGap: CGFloat = 8
}
