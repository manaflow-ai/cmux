import AppKit

extension AgentPaneView {
    /// A native button or menu selection is outside the webview's input monitor. Authenticate
    /// its AppKit event before publishing so the ensuing page request can spend one gesture.
    /// Keep this synchronous: a later task no longer has the selection's current event.
    func invokeTabRowTool(_ id: String, menuItemID: String?, event: NSEvent? = NSApp.currentEvent) {
        guard model.tabRow.nativeToolsEnabled, let pageEvents else { return }
        AgentPanePersonInput.record(model.transport.gestures, event: event)
        pageEvents.publish(.tabRowToolInvoked(id: id, menuItemId: menuItemID))
    }
}
