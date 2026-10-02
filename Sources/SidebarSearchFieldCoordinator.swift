import AppKit

@MainActor
final class SidebarSearchFieldCoordinator: NSObject, NSSearchFieldDelegate {
    var parent: SidebarSearchFieldView

    init(parent: SidebarSearchFieldView) {
        self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? SidebarSearchField else { return }
        parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? SidebarSearchField, !textView.hasMarkedText() else { return false }
        if let event = NSApp.currentEvent, field.handleCommandSubmit(event) { return true }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            parent.onSubmit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !field.stringValue.isEmpty else { return false }
            field.stringValue = ""
            textView.string = ""
            parent.text = ""
            return true
        default:
            return false
        }
    }
}
