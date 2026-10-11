import AppKit

extension NewTabPage {
    /// Choose Folder…: a folder panel, a sheet on `window` when there is
    /// one; nil when the person cancels.
    static func chooseFolder(in window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { done in
            if let window {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}
