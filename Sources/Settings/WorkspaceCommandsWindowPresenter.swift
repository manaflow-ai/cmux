import AppKit

/// Presenter for the Workspaces editor `Window` scene. Mirrors the existing
/// `SettingsWindowPresenter` pattern: the main `WindowGroup`'s onAppear hands
/// in an `openWindow(id:)` closure once, and `AppDelegate.openWorkspaceCommandsWindow`
/// calls `show()` to invoke it. Avoids attaching a view modifier that would
/// change the WindowGroup's content type identity, which silently breaks
/// SwiftUI's scene routing and per-window frame persistence.
@MainActor
enum WorkspaceCommandsWindowPresenter {
    private static var openWindow: (@MainActor () -> Void)?
    private static var shouldOpenWhenConfigured = false

    static func configure(openWindow: @escaping @MainActor () -> Void) {
        self.openWindow = openWindow
        if shouldOpenWhenConfigured {
            shouldOpenWhenConfigured = false
            openWindow()
        }
    }

    static func show() {
        guard let openWindow else {
            shouldOpenWhenConfigured = true
            return
        }
        openWindow()
    }
}
