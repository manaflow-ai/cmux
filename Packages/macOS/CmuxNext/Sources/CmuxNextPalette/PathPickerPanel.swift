import AppKit
import CmuxNextActions
import UniformTypeIdentifiers

/// The system panel behind a palette argument that asks for a file or a folder
/// (``ActionSuggestions/picker``).
enum PathPickerPanel {
    /// The chosen path, nil when the person cancels. A sheet on the key window when there is one.
    @MainActor
    static func choose(_ picker: ActionPicker, title: String) async -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = title
        switch picker {
        case .folder:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
        case .file(let extensions):
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            let types = extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let response = await withCheckedContinuation { done in
            if let window {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url?.path : nil
    }
}
