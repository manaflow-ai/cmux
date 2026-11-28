/// Decides when an alternate-screen keyboard transition may stop showing its
/// frozen last-good frame.
///
/// A keyboard toggle changes the alternate-screen grid. The target size is
/// reported to the Mac when UIKit announces the keyboard frame, but three
/// independent things must happen before the live renderer shows the TUI at
/// that size: UIKit finishes moving the pane, the Mac confirms the PTY resize,
/// and the TUI's redraw for the new size arrives and presents. Revealing
/// earlier shows either a moving surface or the old TUI frame reflowed into
/// the new grid. This value tracks those milestones so the swap happens once,
/// in the frame that already contains the redrawn TUI.
struct KeyboardTransitionPresentationFreeze: Equatable, Sendable {
    private(set) var transitionEnded = false
    /// The viewport report the freeze waits on, once the target is published.
    private(set) var awaitedReportID: UInt64?
    /// A target report that has not been published yet. The surface publishes
    /// it from its first geometry pass at the target, which can run after the
    /// freeze starts.
    private(set) var reportPending = true
    private(set) var reportConfirmed = false
    /// Output applied after the Mac confirmed the resize, and therefore
    /// produced by the TUI after it observed the new PTY size.
    private(set) var outputAppliedAfterConfirmation = false
    /// Render submissions carry monotonic operation IDs. A frame submitted
    /// before the redraw output was applied cannot contain it, so only a
    /// present whose token is above this floor may reveal.
    private(set) var revealTokenFloor: UInt64 = 0
    private(set) var readyToReveal = false

    mutating func noteTransitionEnded() {
        transitionEnded = true
    }

    mutating func noteReportPublished(id: UInt64) {
        awaitedReportID = id
        reportPending = false
        reportConfirmed = false
        outputAppliedAfterConfirmation = false
    }

    /// The target grid equals the grid already reported, so no PTY resize
    /// and no redraw will follow.
    mutating func noteReportUnneeded(lastIssuedToken: UInt64) {
        guard awaitedReportID == nil, reportPending else { return }
        reportPending = false
        reportConfirmed = true
        outputAppliedAfterConfirmation = true
        revealTokenFloor = max(revealTokenFloor, lastIssuedToken)
    }

    mutating func noteReportConfirmed(id: UInt64) {
        guard id == awaitedReportID else { return }
        reportConfirmed = true
    }

    /// - Parameter lastIssuedToken: The newest render token issued before
    ///   the output reached the terminal model.
    mutating func noteOutputApplied(lastIssuedToken: UInt64) {
        guard reportConfirmed else { return }
        outputAppliedAfterConfirmation = true
        revealTokenFloor = max(revealTokenFloor, lastIssuedToken)
    }

    /// Records a renderer present and returns whether the frozen frame can
    /// now be replaced by the live renderer.
    mutating func notePresented(token: UInt64) -> Bool {
        if transitionEnded, !reportPending, reportConfirmed, outputAppliedAfterConfirmation,
           token > revealTokenFloor {
            readyToReveal = true
        }
        return readyToReveal
    }
}
