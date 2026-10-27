public import AppKit
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Shows a folder picker and answers the chosen folder, nil on cancel
/// (`cmux.diff.chooseFolder`). The seam R89's shared palette picker
/// (`CmuxPicker.open`, branch feat-cmux-next-r89-picker) replaces; until it
/// lands, ``OpenPanelFolderChooser`` is the system panel.
public protocol DiffFolderChoosing: AnyObject {
    func chooseFolder(start: URL?, anchor: NSWindow?) async -> URL?
}

public final class OpenPanelFolderChooser: DiffFolderChoosing {
    public init() {}

    public func chooseFolder(start: URL?, anchor: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = DiffPageStrings.chooseFolder
        panel.prompt = DiffPageStrings.chooseButton
        panel.directoryURL = start
        // A panel that went away without an answer chose nothing.
        let response: NSApplication.ModalResponse = (try? await withOnceContinuation {
            (continuation: OnceContinuation<NSApplication.ModalResponse, OnceContinuationError>) in
            if let anchor {
                panel.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }) ?? .cancel
        return response == .OK ? panel.url : nil
    }
}
