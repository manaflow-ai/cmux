import AppKit

/// Presents an `NSAlert` so it reliably appears even when the call originates
/// from inside a SwiftUI `.contextMenu` action or another AppKit
/// menu-tracking handler.
///
/// A bare `NSAlert.runModal()` invoked from such a context can silently
/// no-op: the app may not be the active application and there is no window to
/// host the alert, so the modal session can end immediately and return a
/// cancel response without ever drawing the dialog. Routing every
/// confirmation/prompt through this helper activates the app and presents the
/// alert as a sheet attached to the main cmux window when one is available,
/// falling back to an app-modal `runModal()` only when there is no eligible
/// host window.
///
/// - Parameters:
///   - alert: The configured alert to present.
///   - presentingWindow: An explicit host window. When `nil`, the main cmux
///     window is resolved via ``cmuxMainWindowForModalPresentation()``.
/// - Returns: The modal response selected by the user.
@MainActor
func runCmuxModalAlert(
    _ alert: NSAlert,
    presentingWindow: NSWindow? = nil
) -> NSApplication.ModalResponse {
    if NSApp.activationPolicy() == .regular {
        NSApp.activate(ignoringOtherApps: true)
    }

    let hostWindow = presentingWindow ?? cmuxMainWindowForModalPresentation()
    guard let hostWindow, hostWindow.attachedSheet == nil else {
        return alert.runModal()
    }

    alert.beginSheetModal(for: hostWindow) { result in
        NSApp.stopModal(withCode: result)
    }
    return NSApp.runModal(for: alert.window)
}

/// Returns the visible main cmux window best suited to host a modal sheet.
///
/// Prefers the key window, then the main window, then any visible main
/// window. Returns `nil` when no main cmux window is currently on screen, in
/// which case callers should fall back to an app-modal presentation.
@MainActor
func cmuxMainWindowForModalPresentation() -> NSWindow? {
    func isMainWindow(_ candidate: NSWindow) -> Bool {
        guard let raw = candidate.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }
    if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, isMainWindow(keyWindow) {
        return keyWindow
    }
    if let mainWindow = NSApp.mainWindow, mainWindow.isVisible, isMainWindow(mainWindow) {
        return mainWindow
    }
    return NSApp.windows.first { $0.isVisible && isMainWindow($0) }
}
