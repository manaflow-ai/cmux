import AppKit
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension NewTabPage {
    /// Choose Folder…: a folder panel, a sheet on `window` when there is
    /// one; nil when the person cancels.
    static func chooseFolder(in window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // A panel that drops its reply was cancelled.
        let response = (try? await withOnceContinuation { (done: OnceContinuation<NSApplication.ModalResponse, OnceContinuationError>) in
            if let window {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }) ?? .cancel
        return response == .OK ? panel.url : nil
    }
}
