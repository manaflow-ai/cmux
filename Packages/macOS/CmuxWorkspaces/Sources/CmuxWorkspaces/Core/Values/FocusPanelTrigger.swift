/// Why a panel-focus pass is running, so focus application can distinguish
/// a standard programmatic focus from one initiated by the terminal view
/// becoming first responder. Formerly `Workspace.FocusPanelTrigger`.
public enum FocusPanelTrigger: Sendable, Equatable {
    /// A regular focus request (selection change, split navigation, restore).
    case standard
    /// Focus driven by the terminal view taking AppKit first responder.
    case terminalFirstResponder
}
