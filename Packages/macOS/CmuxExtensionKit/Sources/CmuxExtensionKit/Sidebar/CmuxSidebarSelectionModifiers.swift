/// The selection gestures supported by the native workspace sidebar.
///
/// Only Command and Shift affect workspace selection. Extensions cannot send
/// arbitrary event flags or a replacement selection to the host.
public struct CmuxSidebarSelectionModifiers: Codable, Equatable, Sendable {
    /// Toggles a workspace, or extends the current Shift range.
    public var command: Bool
    /// Selects a range using the host's current native selection anchor.
    public var shift: Bool

    /// Creates modifiers captured from one user workspace click.
    ///
    /// - Parameters:
    ///   - command: Whether the click held Command.
    ///   - shift: Whether the click held Shift.
    public init(command: Bool = false, shift: Bool = false) {
        self.command = command
        self.shift = shift
    }
}
