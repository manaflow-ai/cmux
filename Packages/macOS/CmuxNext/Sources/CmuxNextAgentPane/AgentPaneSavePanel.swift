import AppKit
import CmuxNextCompat

/// Owns the native save panel for one agent pane: the inspector's log and side panel documents.
@MainActor
final class AgentPaneSavePanel {
    private var isSaving = false

    /// Asks where to save `save` and writes its text there. Returns false when the user cancels
    /// or a save panel is already up.
    func save(_ save: AgentPaneSave, window: NSWindow?) async throws -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let panel = NSSavePanel()
        panel.title = save.kind == .log
            ? String(localized: "agentPane.inspector.saveLog", defaultValue: "Save ACP Log", bundle: .module)
            : String(localized: "agentPane.saveDocument", defaultValue: "Save Document", bundle: .module)
        panel.nameFieldStringValue = save.suggestedName
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
        try await Self.write(save.text, to: url)
        return true
    }

    /// Writes the chosen file atomically, off the main actor (the user can pick a slow or network
    /// volume); a failure throws back to the caller, as before.
    @concurrent nonisolated private static func write(_ text: String, to url: URL) async throws {
        try Data(text.utf8).blockingWrite(to: url, options: .atomic)
    }
}
