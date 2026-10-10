import AppKit

// The fields of a dialog with a user-only button (cx-zk9t): an accessibility write of
// a text field's value or a press of a check box changes what the person's confirm
// does, so it is refused unless an assistive technology runs (`CmuxPersonInput`).
// The person's own typing and clicks are unchanged.

/// A dialog text field that refuses accessibility value writes while its dialog is user-only.
final class CmuxDialogTextField: NSTextField {
    var userOnly = false

    override func setAccessibilityValue(_ value: Any?) {
        if userOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return }
        super.setAccessibilityValue(value)
    }
}

/// The secure variant (passwords).
final class CmuxDialogSecureField: NSSecureTextField {
    var userOnly = false

    override func setAccessibilityValue(_ value: Any?) {
        if userOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return }
        super.setAccessibilityValue(value)
    }
}

/// A dialog check box that refuses accessibility presses while its dialog is user-only.
final class CmuxDialogCheckbox: NSButton {
    var userOnly = false

    override func accessibilityPerformPress() -> Bool {
        if userOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return false }
        return super.accessibilityPerformPress()
    }
}
