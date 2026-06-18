import AppKit

/// How ``runCmuxModalAlert(_:presentingWindow:willPresent:)`` ended up
/// presenting an alert.
///
/// Reported to the `willPresent` hook from inside the presenter so callers
/// observe the *actual* path taken rather than re-deriving it (which can
/// drift from the presenter's own decision).
enum CmuxModalAlertPresentation {
    /// Presented as a sheet attached to the associated host window.
    case sheet(NSWindow)
    /// Presented application-modal because no eligible host window was found.
    ///
    /// - Parameter hostWindowHadAttachedSheet: `true` when a candidate host
    ///   window existed but was rejected because it already had a sheet
    ///   attached; `false` when no candidate window was found at all.
    case appModal(hostWindowHadAttachedSheet: Bool)
}

/// Returns whether `window` is one of cmux's main windows.
///
/// Main windows carry the identifier `cmux.main` or a `cmux.main.<id>`
/// per-window variant. This is the single source of truth for that match so
/// the identifier scheme only has to change in one place.
@MainActor
func isCmuxMainWindow(_ window: NSWindow) -> Bool {
    guard let raw = window.identifier?.rawValue else { return false }
    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
}

/// Returns the visible main cmux window best suited to host a modal sheet.
///
/// Prefers `preferredWindow` when supplied and eligible, then the key
/// window, then the main window, then any visible main window. Returns `nil`
/// when no main cmux window is currently on screen, in which case callers
/// should fall back to an app-modal presentation.
///
/// - Parameter preferredWindow: A window to consider ahead of the
///   key/main/any search, used when it is visible and a cmux main window
///   (e.g. a `TabManager`'s own owning window).
@MainActor
func cmuxMainWindowForModalPresentation(preferring preferredWindow: NSWindow? = nil) -> NSWindow? {
    if let preferredWindow, preferredWindow.isVisible, isCmuxMainWindow(preferredWindow) {
        return preferredWindow
    }
    if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, isCmuxMainWindow(keyWindow) {
        return keyWindow
    }
    if let mainWindow = NSApp.mainWindow, mainWindow.isVisible, isCmuxMainWindow(mainWindow) {
        return mainWindow
    }
    return NSApp.windows.first { $0.isVisible && isCmuxMainWindow($0) }
}

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
///     window is resolved via ``cmuxMainWindowForModalPresentation(preferring:)``.
///   - willPresent: Invoked synchronously with the chosen presentation just
///     before the modal session begins, so callers can record telemetry from
///     the path the presenter actually takes instead of re-deriving it.
/// - Returns: The modal response selected by the user.
@MainActor
func runCmuxModalAlert(
    _ alert: NSAlert,
    presentingWindow: NSWindow? = nil,
    willPresent: ((CmuxModalAlertPresentation) -> Void)? = nil
) -> NSApplication.ModalResponse {
    if NSApp.activationPolicy() == .regular {
        NSApp.activate(ignoringOtherApps: true)
    }

    let hostWindow = presentingWindow ?? cmuxMainWindowForModalPresentation()
    guard let hostWindow, hostWindow.attachedSheet == nil else {
        willPresent?(.appModal(hostWindowHadAttachedSheet: hostWindow?.attachedSheet != nil))
        return alert.runModal()
    }

    willPresent?(.sheet(hostWindow))
    alert.beginSheetModal(for: hostWindow) { result in
        NSApp.stopModal(withCode: result)
    }
    return NSApp.runModal(for: alert.window)
}
