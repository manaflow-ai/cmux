/// The side effects a terminal panel should apply when Compose Mode changes.
public enum TerminalComposeModeTransition: Equatable, Sendable {
    /// The preference activated the composer for this panel.
    case activate

    /// The preference deactivated a composer it previously activated.
    case deactivate

    /// No composer ownership change is required.
    case unchanged
}

/// Keeps the global Compose Mode preference from taking over a manually opened
/// TextBox. Only a composer activated by the preference is released when the
/// preference is turned off.
public struct TerminalComposeModePolicy: Sendable {
    /// Creates a Compose Mode transition policy.
    public init() {}

    /// Determines the ownership transition for a terminal panel.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the global Compose Mode preference is enabled.
    ///   - ownsTextBox: Whether Compose Mode activated the panel's TextBox.
    ///   - isTextBoxActive: Whether the panel already has a manually activated TextBox.
    /// - Returns: The side effect needed to reconcile the panel with the preference.
    public func transition(
        isEnabled: Bool,
        ownsTextBox: Bool,
        isTextBoxActive: Bool
    ) -> TerminalComposeModeTransition {
        switch (isEnabled, ownsTextBox) {
        case (true, false) where !isTextBoxActive:
            return .activate
        case (false, true):
            return .deactivate
        default:
            return .unchanged
        }
    }
}
