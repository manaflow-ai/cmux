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
        TerminalSelection.read(of: self)?.text
    }

    // A text area's text and the attributes VoiceOver reads it by (as upstream Ghostty's SurfaceView
    // answers them), from the viewport: what the person sees, bounded by the grid, not the scrollback.
    // Each read is on the accessibility server's request only, never on a typing or drawing path.

    public override func accessibilityValue() -> Any? { accessibleText().string }

    public override func accessibilityNumberOfCharacters() -> Int { accessibleText().length }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibleText().length)
    }

    public override func accessibilityLine(for index: Int) -> Int { accessibleText().line(for: index) }

    public override func accessibilityRange(forLine line: Int) -> NSRange { accessibleText().range(forLine: line) }

    public override func accessibilityString(for range: NSRange) -> String? { accessibleText().string(for: range) }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = accessibleText().string(for: range) else { return nil }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let surface, let font = unsafe GhosttyTextRead.quickLookFont(surface) else { return NSAttributedString(string: text) }
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    /// The viewport's text, read at most once per ``TerminalAccessibleTextCache/lifetime``.
    private func accessibleText() -> TerminalAccessibleText {
        accessibleTextCache.text(now: .now) { viewportText() }
    }
}
