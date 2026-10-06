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
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
}
