public import AppKit

public extension NSSavePanel {
    /// Shows the panel as a sheet on `window` (else the key or main window,
    /// else on its own) and calls `done` with the chosen URL, or nil. Never
    /// an app-modal run loop. INTERIM: the R89 cmux file picker replaces
    /// every open and save panel (R96 decision D2).
    func beginForCmux(in window: NSWindow? = nil, done: @escaping (URL?) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            done(response == .OK ? self?.url : nil)
        }
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            beginSheetModal(for: window, completionHandler: finish)
        } else {
            begin(completionHandler: finish)
        }
    }
}
