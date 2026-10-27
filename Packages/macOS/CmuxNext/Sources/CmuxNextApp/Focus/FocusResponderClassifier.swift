import AppKit
import CmuxNextDesign
import CmuxNextFocus

/// Maps an AppKit first responder of a cmux window to what the focus state
/// machine understands (`FocusEvent.Responder`). The field editor of a text
/// field is a subview of that field while editing, so it classifies with it.
enum FocusResponderClassifier {
    static func classify(_ responder: NSResponder?, in controller: WindowController) -> FocusEvent.Responder {
        guard let view = responder as? NSView else { return .windowOrNone }
        // A control of the window's top layer while a modal shows (a dialog's field or button) holds the
        // keyboard outside every pane, as a text field does: the focus model leaves it there (not
        // `windowOrNone`, which re-applies the pane's focus and would take the keyboard from the dialog).
        if let window = controller.window, let host = WindowOverlayHost.existingHost(for: window),
           host.holdsKeyboardInWindowTopLayer(view) {
            return .textField
        }
        if view.isDescendant(of: controller.sidebar.container) {
            return isText(view) ? .sidebarField : .sidebar
        }
        if let content = controller.content {
            for pane in content.panes.values where view.isDescendant(of: pane.view) {
                if case .browser(let entry)? = pane.currentContent, let region = entry.chrome.region(of: view) {
                    switch region {
                    case .addressBar: return .addressBar(pane: pane.paneKey)
                    case .findBar: return .findBar(pane: pane.paneKey)
                    case .page: return .content(pane: pane.paneKey)
                    case .chrome: return isText(view) ? .textField : .content(pane: pane.paneKey)
                    }
                }
                // The terminal's find bar field: a text input over the terminal.
                if case .terminal(let entry)? = pane.currentContent, isText(view), view.isDescendant(of: entry.session.view) {
                    return .textField
                }
                return .content(pane: pane.paneKey)
            }
        }
        return isText(view) ? .textField : .windowOrNone
    }

    static func isText(_ view: NSView) -> Bool { view is NSText || view is NSTextField }

    /// Stable name of an AppKit responder for `debug.focus`.
    static func describe(_ responder: FocusEvent.Responder) -> String {
        switch responder {
        case .content(let pane): "content:\(pane)"
        case .addressBar(let pane): "addressBar:\(pane)"
        case .findBar(let pane): "findBar:\(pane)"
        case .devTools(let pane): "devTools:\(pane)"
        case .sidebar: "sidebar"
        case .sidebarField: "sidebarField"
        case .textField: "textField"
        case .windowOrNone: "windowOrNone"
        }
    }
}
