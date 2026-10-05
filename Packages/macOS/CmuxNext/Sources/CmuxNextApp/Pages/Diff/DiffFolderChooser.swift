import AppKit

/// Shows a folder picker and answers the chosen folder, nil on cancel
/// (`cmux.diff.chooseFolder`). The seam R89's shared palette picker
/// (`CmuxPicker.open`, branch feat-cmux-next-r89-picker) replaces; until it
/// lands, ``OpenPanelFolderChooser`` is the system panel.
protocol DiffFolderChoosing: AnyObject {
    func chooseFolder(start: URL?, anchor: NSWindow?) async -> URL?
}

final class OpenPanelFolderChooser: DiffFolderChoosing {
    func chooseFolder(start: URL?, anchor: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = DiffPageStrings.chooseFolder
        panel.prompt = DiffPageStrings.chooseButton
        panel.directoryURL = start
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let anchor {
                panel.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}
