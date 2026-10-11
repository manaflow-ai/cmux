import AppKit

/// Owns the native save panel for one agent pane.
@MainActor
final class AgentPaneLogExport {
    private var isSavingLog = false

    /// Asks where to save the inspector's exported log and writes it there.
    /// Returns false when the user cancels or a save panel is already up.
    func save(_ text: String, suggestedName: String, window: NSWindow?) async throws -> Bool {
        guard !isSavingLog else { return false }
        isSavingLog = true
        defer { isSavingLog = false }
        let panel = NSSavePanel()
        panel.title = String(localized: "agentPane.inspector.saveLog", defaultValue: "Save ACP Log", bundle: .module)
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
