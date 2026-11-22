import AppKit

/// Close in the label of a pane that still starts (``TerminalStatusBanner/startingOverdueDelay``
/// after it began): the daemon has not confirmed the pane's terminal, so the person can stop waiting.
extension TerminalHostView {
    /// The App's Close Tab for this tab, the one path of its shortcut and of the tab's close button.
    /// With none set the label offers no Close.
    public var onCloseStarting: (@MainActor () -> Void)? {
        get { statusLabel.onClose }
        set { statusLabel.onClose = newValue }
    }

    /// The title of the Close the label offers now, nil while it offers none (tests).
    var startingCloseTitle: String? { statusLabel.closeTitle }

    /// Presses the offered Close as a click on it does; false while none is offered (tests).
    @discardableResult
    func pressStartingClose() -> Bool { statusLabel.pressClose() }
}
