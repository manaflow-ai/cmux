/// A TextBox control that runs a registry action. The raw value is the action's id; the App maps
/// it to `ActionID` and runs it through the registry (`TextBoxHandlers`), so this target needs no
/// dependency on CmuxNextActions.
package nonisolated enum TextBoxCommand: String, Sendable, CaseIterable {
    /// Shift-Tab or the submit action button: the next submit action.
    case cycleSubmitAction = "cycleTextBoxSubmitAction"
    /// The Add Files button.
    case attachFile = "attachTextBoxFile"
}
