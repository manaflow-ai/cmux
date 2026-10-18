public import AppKit

/// Add Files to Project's open panel (cx-ncc.67): a sheet on the pane's window for files, several
/// at a time. None when the user cancels or the pane has no window. The model asks for it only
/// after a real gesture.
public struct AgentPaneFilePicker {
    public init() {}
    @MainActor public static func pick(window: NSWindow?) async -> [URL] {
        guard let window else { return [] }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "agentPane.addFiles.prompt", defaultValue: "Add", bundle: .module)
        panel.message = String(localized: "agentPane.addFiles.message",
                               defaultValue: "Every chat in this folder reads the files you add.", bundle: .module)
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : []
    }

    /// Attach files or folders (`chat.attach.choose`): the same sheet for files and folders, several
    /// at a time. None when the user cancels or the pane has no window.
    @MainActor public static func pickAttachments(window: NSWindow?) async -> [URL] {
        guard let window else { return [] }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "agentPane.attach.prompt", defaultValue: "Attach", bundle: .module)
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : []
    }
}
