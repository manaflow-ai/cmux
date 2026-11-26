public import AppKit

extension NSApplication {
    /// The app's focused accessibility element, where VoiceOver's cursor draws: its class, role, identifier, its
    /// frame on screen and its parent's frame, for `debug.focus` (a stale frame shows the cursor at an old place).
    public var accessibilityFocusReport: String {
        guard let element = accessibilityFocusedUIElement as? NSAccessibilityProtocol else { return "none" }
        let parent = (element.accessibilityParent() as? NSAccessibilityProtocol)?.accessibilityFrame()
        return "\(type(of: element)) role \(element.accessibilityRole()?.rawValue ?? "-") id \(element.accessibilityIdentifier() ?? "-") "
            + "frame \(NSStringFromRect(element.accessibilityFrame())) parent \(parent.map(NSStringFromRect) ?? "-")"
    }
}
