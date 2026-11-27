import AppKit

/// cmux: Save As… for a Home attachment: the system save panel, named like the attachment, then
/// a copy of its bytes where the person chose (an older file there is replaced: the panel already
/// asked).
struct HomeAttachmentSave {
    /// Copies `file` to `destination`, replacing a file already there.
    func save(_ file: URL, to destination: URL) throws {
        let files = FileManager.default
        if file.standardizedFileURL == destination.standardizedFileURL { return }
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        try files.copyItem(at: file, to: staged)
        do {
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staged)
            } else {
                try files.moveItem(at: staged, to: destination)
            }
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    /// Asks where to save `file` (named `name`) with the save panel, as a sheet on `window` when
    /// there is one, and saves it there; a failure shows the system's error alert.
    @MainActor func ask(_ file: URL, name: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.isEmpty ? file.lastPathComponent : (name as NSString).lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try save(file, to: destination)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}
