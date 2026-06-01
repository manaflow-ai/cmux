import AppKit
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

@MainActor
final class SettingsAppKitWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsAppKitWindowPresenter()

    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsAppKitWindowRoot>?

    func show(runtime: SettingsRuntime) {
        if let window {
            SettingsWindowPresenter.configure(window: window)
            SettingsWindowPresenter.refocusIfVisible()
            return
        }

        let root = SettingsAppKitWindowRoot(runtime: runtime)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "settings.title", defaultValue: "Settings")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        self.hostingController = hostingController
        SettingsWindowPresenter.configure(window: window)
        SettingsWindowPresenter.refocusIfVisible()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct SettingsAppKitWindowRoot: View {
    let runtime: SettingsRuntime
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    var body: some View {
        SettingsWindowRoot(runtime: runtime)
            .settingsRuntime(runtime)
            .background(WindowAccessor(dedupeByWindow: false) { window in
                SettingsWindowPresenter.configure(window: window)
            })
            .cmuxAppearanceColorScheme(appearanceMode)
    }
}
