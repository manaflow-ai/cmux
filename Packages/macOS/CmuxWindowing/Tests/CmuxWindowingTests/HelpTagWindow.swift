import AppKit

/// Test double that reports the `.helpTag` accessibility role so tests can
/// verify tooltip (help-tag) windows are filtered out of `AXWindows`.
final class HelpTagWindow: NSWindow {
    override func accessibilityRole() -> NSAccessibility.Role? {
        .helpTag
    }
}
