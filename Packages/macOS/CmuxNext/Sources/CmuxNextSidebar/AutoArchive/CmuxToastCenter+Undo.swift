public import AppKit
public import CmuxNextDesign

extension CmuxToastCenter {
    /// Shows `message` with an Undo button (Cmd-Z while it shows) in `window` for 10 seconds; `undo` runs on
    /// it. No window: nothing shows (auto-archive's toast; the change itself already happened).
    public func showUndo(_ message: String, id: String, in window: NSWindow?, undo: @escaping @MainActor () -> Void) {
        guard let window else { return }
        show(CmuxToast(id: id, message: message, action: .undo(), duration: .seconds(10)), in: window).onAction = { undo() }
    }
}
