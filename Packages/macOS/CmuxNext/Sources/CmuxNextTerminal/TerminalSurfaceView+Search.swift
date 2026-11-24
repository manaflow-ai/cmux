public import AppKit
import GhosttyNextKit

// Accessibility. Find-in-terminal lives in TerminalSession+Find.
extension TerminalSurfaceView {
    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityLabel() -> String? {
        let title = session?.model.title ?? ""
        return title.isEmpty ? String(localized: "terminal.accessibility.label", defaultValue: "Terminal", bundle: .localizedModule) : title
    }

    public override func accessibilitySelectedText() -> String? {
        TerminalSelection.read(surface)?.text
    }

    // The insertion point, for assistive apps and screen sharing's Follow mode
    // (CmuxVNCWebRTC's SystemFocusProbe reads AXSelectedTextRange, then
    // AXBoundsForRange): the range input methods see, and for any range the
    // terminal cursor as a zero-width rect in screen coordinates, the same
    // rect the IME candidate window is placed at (ghostty_surface_ime_point).

    public override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    }
}
