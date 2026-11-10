public import AppKit
public import CmuxNextDesign

/// Add Files to Project's open panel (cx-ncc.67): a sheet on the pane's window for files, several
/// at a time. None when the user cancels, the pane has no window, or the panel came back dead (no
/// GUI session: no sheet is shown, so nothing waits on it). The model asks for it only
/// after a real gesture. Each sheet takes a new panel from the app's picker (`MadeAheadOpenPanel`).
@MainActor
public struct AgentPaneFilePicker {
    private let openPanel: MadeAheadOpenPanel

    /// - Parameter openPanel: The app's file picker (`AppServices.openPanel`).
    public init(openPanel: MadeAheadOpenPanel) {
        self.openPanel = openPanel
    }

    public func pick(window: NSWindow?) async -> [URL] {
        guard let window, let panel = openPanel.panel() else { return [] }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "agentPane.addFiles.prompt", defaultValue: "Add", bundle: .module)
        panel.message = String(localized: "agentPane.addFiles.message",
                               defaultValue: "Every chat in this folder reads the files you add.", bundle: .module)
        return await sheet(panel, on: window)
    }

    /// Attach files or folders (`chat.attach.choose`): the same sheet for files and folders, several
    /// at a time. None when the user cancels, the pane has no window, or the panel came back dead.
    public func pickAttachments(window: NSWindow?) async -> [URL] {
        guard let window, let panel = openPanel.panel() else { return [] }
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "agentPane.attach.prompt", defaultValue: "Attach", bundle: .module)
        return await sheet(panel, on: window)
    }

    /// The chosen files, read in the sheet's own handler; the handler is the panel's last owner, so the
    /// panel goes when its sheet ended.
    private func sheet(_ panel: NSOpenPanel, on window: NSWindow) async -> [URL] {
        await withCheckedContinuation { done in
            panel.beginSheetModal(for: window) { response in done.resume(returning: response == .OK ? panel.urls : []) }
        }
    }
}
