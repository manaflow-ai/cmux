#if canImport(AppKit)

public import Foundation

/// The app-coupled actions the browser-debug panels invoke.
///
/// The two browser-debug panels (``BrowserImportHintDebugView`` and
/// ``BrowserProfilePopoverDebugView``) are otherwise pure UI over `UserDefaults`,
/// but their quick-action buttons reach into the running app: they open the
/// Browser settings pane, present the live browser data-import dialog, and reset
/// the import-hint debug defaults. Those behaviors live in the app target
/// (`AppDelegate.presentPreferencesWindow`, `BrowserDataImportCoordinator`,
/// `BrowserImportHintSettings.reset()`).
///
/// This package inverts that reach: it publishes this read-only seam, the app
/// target conforms one object to it, and ``DebugWindowsCoordinator`` injects the
/// conformer through its existing decorator channel. The package therefore owns
/// no reference to `AppDelegate`, the import coordinator, or the app-target
/// settings namespaces. This mirrors how the coordinator already takes the
/// ``WindowDecorating`` seam instead of importing the application delegate.
@MainActor
public protocol BrowserDebugContext: AnyObject {
    /// Opens the app's Settings window navigated to the Browser pane.
    func presentBrowserPreferences()

    /// Presents the live browser data-import dialog.
    func presentBrowserImportDialog()

    /// Resets the import-hint debug defaults to their shipped values.
    func resetBrowserImportHintDebugState()
}

#endif
