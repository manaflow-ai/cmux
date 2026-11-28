public import AppKit
import GhosttyNextKit

// Accessibility. Find-in-terminal lives in TerminalSession+Find.
extension TerminalSurfaceView {
    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityLabel() -> String? {
        let title = session?.model.title ?? ""
        return title.isEmpty ? String(localized: "terminal.accessibility.label", defaultValue: "Terminal", bundle: .module) : title
    }

    public override func accessibilitySelectedText() -> String? {
        TerminalSelection.read(surface)?.text
    }
}
