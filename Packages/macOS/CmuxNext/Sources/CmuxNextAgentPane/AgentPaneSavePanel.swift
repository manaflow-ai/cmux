import AppKit
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        // A sheet on the pane's window, else a free panel: never a nested modal loop.
        // A panel dropped without its handler (abandoned) chose nothing.
        let chosen = (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
            } else {
                panel.begin { continuation.resume(returning: $0 == .OK) }
            }
        }) ?? false
        guard chosen, let url = panel.url else { return false }
        try Data(save.text.utf8).write(to: url, options: .atomic)
        return true
    }
}
