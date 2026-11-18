public import AppKit

extension CmuxToastCenter {
    /// Shows `message` for 3 seconds in `window`, else the key window; no window: nothing shows (the
    /// change itself already happened). A host's one-line toast forward calls this.
    public func showNotice(_ message: String, id: String, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow else { return }
        show(CmuxToast(id: id, message: message, duration: .seconds(3)), in: window)
    }
}
