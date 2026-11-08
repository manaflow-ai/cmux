import AppKit

/// How ``NSAlert/runCmuxModal(presentingWindow:content:willPresent:)`` ended up
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

private extension NSWindow {
    /// Whether this window is one of cmux's main windows.
    var isCmuxMainWindow: Bool {
        guard let raw = identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }
}

extension NSApplication {
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
        if let preferredWindow, preferredWindow.isVisible, preferredWindow.isCmuxMainWindow {
            return preferredWindow
        }
        if let keyWindow, keyWindow.isVisible, keyWindow.isCmuxMainWindow {
            return keyWindow
        }
        if let mainWindow, mainWindow.isVisible, mainWindow.isCmuxMainWindow {
            return mainWindow
        }
        return windows.first { $0.isVisible && $0.isCmuxMainWindow }
    }
}

extension NSAlert {
    /// Presents this alert reliably from menu-tracking and ordinary AppKit contexts.
    ///
    /// The application is activated, then the alert is presented as a sheet on
    /// an eligible cmux main window. If no host is available or the host already
    /// owns a sheet, presentation falls back to an application-modal session.
    ///
    /// - Parameters:
    ///   - presentingWindow: An explicit host window. When `nil`, the main cmux
    ///     window is resolved by ``NSApplication/cmuxMainWindowForModalPresentation(preferring:)``.
    ///   - content: Structured alert copy whose user-sized details are bounded to
    ///     the presenting screen and made internally scrollable.
    ///   - willPresent: Invoked synchronously with the chosen presentation just
    ///     before the modal session begins.
    /// - Returns: The modal response selected by the user.
    @MainActor
    func runCmuxModal(
        presentingWindow: NSWindow? = nil,
        content: CmuxAlertContent? = nil,
        willPresent: ((CmuxModalAlertPresentation) -> Void)? = nil
    ) -> NSApplication.ModalResponse {
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }

        let hostWindow = presentingWindow ?? NSApp.cmuxMainWindowForModalPresentation()
        if let content {
            content.apply(to: self, presentingWindow: hostWindow)
        } else if accessoryView == nil, !informativeText.isEmpty {
            CmuxAlertContent(informativeText: informativeText)
                .apply(to: self, presentingWindow: hostWindow)
        }
        guard let hostWindow, hostWindow.attachedSheet == nil else {
            willPresent?(.appModal(hostWindowHadAttachedSheet: hostWindow?.attachedSheet != nil))
            return runModal()
        }

        willPresent?(.sheet(hostWindow))
        beginSheetModal(for: hostWindow) { result in
            NSApp.stopModal(withCode: result)
        }
        return NSApp.runModal(for: window)
    }
}
