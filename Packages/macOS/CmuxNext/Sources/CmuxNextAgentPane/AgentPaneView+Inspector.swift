public import AppKit

// The page's ACP inspector, from the host side: the palette toggles it
// (`agentPane.toggleInspector`), and its Export saves through a save panel
// (`pane.saveLog`).
extension AgentPaneView {
    /// Opens the inspector when `open` is true, closes it when false, and
    /// toggles it when nil. A page that has not loaded its bridge yet
    /// ignores it.
    public func toggleInspector(open: Bool? = nil) {
        evaluateScript(Self.inspectorScript(open: open))
    }

    /// The script that calls the page's `cmuxAcpmuxBridge.toggleInspector`.
    static func inspectorScript(open: Bool?) -> String {
        let argument = open.map { $0 ? "true" : "false" } ?? ""
        return "window.cmuxAcpmuxBridge?.toggleInspector?.(\(argument));"
    }

    /// Asks where to save the inspector's exported log and writes it there.
    /// Returns false when the user cancels or a save panel is already up.
    func saveLog(_ text: String, suggestedName: String) async throws -> Bool {
        guard !isSavingLog else { return false }
        isSavingLog = true
        defer { isSavingLog = false }
        let panel = NSSavePanel()
        panel.title = Self.saveLogTitle
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }
}
