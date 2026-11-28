import AppKit
public import WebKit

extension WKWebView {
    /// Delivers automation's right-button press. The page gets it as usual
    /// (`mousedown`, `contextmenu`); the native context menu WebKit then
    /// asks for is not shown, since it would take the person's mouse and
    /// keyboard. Only this press is marked: a person's press keeps its menu.
    public func agentRightMouseDown(_ event: NSEvent) {
        guard let view = self as? WebKitWebView else { return rightMouseDown(with: event) }
        view.agentMenuEvent = event
        view.rightMouseDown(with: event)
    }
}
