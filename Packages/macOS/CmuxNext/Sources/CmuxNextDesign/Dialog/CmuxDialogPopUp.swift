import AppKit

/// A dialog choice that refuses accessibility presses and menu opens while its dialog is
/// user-only (cx-zk9t), unless an assistive technology runs (`CmuxPersonInput`).
final class CmuxDialogPopUp: NSPopUpButton {
    var userOnly = false

    override func accessibilityPerformPress() -> Bool {
        if userOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return false }
        return super.accessibilityPerformPress()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        if userOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return false }
        return super.accessibilityPerformShowMenu()
    }
}
