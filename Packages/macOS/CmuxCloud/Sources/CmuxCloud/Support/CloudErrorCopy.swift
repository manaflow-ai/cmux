import AppKit

/// Shared action for SwiftUI errors, outline rows, AppKit overlays and alert bodies.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
@MainActor
public enum CloudErrorCopy: Sendable {
    public static var title: String { String(localized: "machines.pending.copyError", defaultValue: "Copy Error") }

    public static func copy(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public static func menu(_ text: String, pasteboard: NSPasteboard = .general) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(CloudTreeMenuItem(title: title) { copy(text, pasteboard: pasteboard) })
        return menu
    }

    /// Use only the alert's presented text, preserving its existing redaction policy.
    public static func install(in alert: NSAlert, text: String) {
        alert.layout()
        guard let root = alert.window.contentView else { return }
        install(in: root, text: text)
    }

    private static func install(in view: NSView, text: String) {
        view.menu = menu(text)
        for child in view.subviews { install(in: child, text: text) }
    }
}
