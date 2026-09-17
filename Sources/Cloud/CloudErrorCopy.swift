import AppKit

/// Shared action for SwiftUI errors, outline rows, AppKit overlays and alert bodies.
@MainActor
enum CloudErrorCopy {
    static var title: String { String(localized: "machines.pending.copyError", defaultValue: "Copy Error") }

    static func copy(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func menu(_ text: String, pasteboard: NSPasteboard = .general) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(CloudTreeMenuItem(title: title) { copy(text, pasteboard: pasteboard) })
        return menu
    }

    /// Use only the alert's presented text, preserving its existing redaction policy.
    static func install(in alert: NSAlert, text: String) {
        alert.layout()
        guard let root = alert.window.contentView else { return }
        install(in: root, text: text)
    }

    private static func install(in view: NSView, text: String) {
        view.menu = menu(text)
        for child in view.subviews { install(in: child, text: text) }
    }
}
