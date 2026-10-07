public import AppKit

extension AgentPaneView {
    /// "Choose Folder…" (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the native folder sheet on this
    /// pane's window. Folders only, one at a time; nil when the user cancels or the pane has no
    /// window. The model asks for it only after a real gesture.
    public func pickFolder() async -> URL? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.prompt = Self.chooseFolderPrompt
        panel.message = Self.chooseFolderMessage
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }

    static var chooseFolderPrompt: String {
        String(localized: "agentPane.chooseFolder.prompt", defaultValue: "Choose", bundle: .module)
    }

    static var chooseFolderMessage: String {
        String(localized: "agentPane.chooseFolder.message",
               defaultValue: "New agent chats in this workspace start in the folder you choose.", bundle: .module)
    }
}
