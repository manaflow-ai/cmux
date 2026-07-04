import AppKit
import SwiftUI

/// Owns the single extension-consent window (install/update preview). Reuses
/// the open window on repeated requests; hosts ``ExtensionConsentView`` over
/// the shared ``ExtensionInstallCoordinator``. Mirrors the pairing-window
/// controller pattern.
@MainActor
final class ExtensionConsentWindowController: ReleasingWindowController {
    static let shared = ExtensionConsentWindowController()

    /// Listed in `cmuxAuxiliaryWindowIdentifiers` (cmuxApp.swift) so Cmd+W
    /// closes this window instead of a terminal tab behind it.
    static let windowIdentifier = "cmux.extensionInstall"

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the consent window to the front, creating it if needed.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showManagedWindow(orderFrontRegardless: true)
    }

    /// Closes the window if open.
    func closeWindow() {
        window?.close()
    }

    override func makeWindow() -> NSWindow {
        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let root = ExtensionConsentView(
            coordinator: DockExtensionsRuntime.shared.installCoordinator
        )
        .cmuxAppearanceColorScheme(appearanceMode)
        let hostingController = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "extensions.consent.window.title", defaultValue: "Install Extension")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 560))
        window.contentMinSize = NSSize(width: 460, height: 380)
        window.center()
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        // Red-button/Cmd+W close is a cancel: never leak a staged checkout.
        DockExtensionsRuntime.shared.installCoordinator.handleWindowClosed()
    }
}
