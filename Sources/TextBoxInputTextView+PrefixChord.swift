import AppKit

extension TextBoxInputTextView {
    /// Runs the submit-action cycle without requiring the text view to observe
    /// the consumed leader stroke itself.
    @discardableResult
    func performPrefixChordSubmitActionCycle() -> Bool {
        guard window?.firstResponder === self else { return false }
        onCycleSubmitAction()
        return true
    }

    func textBoxShortcut(
        _ event: NSEvent,
        matches action: KeyboardShortcutSettings.Action
    ) -> Bool {
        let matches = AppDelegate.shared?.matchConfiguredShortcut(event: event, action: action)
            ?? KeyboardShortcutSettings.shortcut(for: action).matches(event: event)
        guard matches else { return false }
        return AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
    }
}
