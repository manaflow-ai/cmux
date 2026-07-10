import AppKit
import CmuxFoundation
import CmuxSettingsUI
import SwiftUI
import os

/// Builds the AppKit-owned Settings window
/// (https://github.com/manaflow-ai/cmux/issues/7777).
///
/// Construction is synchronous and infallible: unlike the previous SwiftUI
/// `Window` scene + `openWindow(id:)` path, a call here always returns a real
/// `NSWindow`, so ``SettingsWindowPresenter`` can guarantee an open request
/// ends with a visible window. SwiftUI is used only for the window's content.
@MainActor
enum SettingsWindowFactory {
    private nonisolated static let log = Logger(subsystem: "com.cmuxterm.app", category: "Settings")

    static func makeSettingsWindow() -> NSWindow {
        if AppDelegate.shared?.settingsRuntime == nil {
            // ``SettingsWindowHostRoot`` presents a visible, localized error
            // in this state — loud, never a silent no-op (issue #7777).
            log.fault("settings.window.factory settingsRuntime unavailable; presenting fallback content")
        }
        let hostingController = NSHostingController(rootView: SettingsWindowHostRoot())
        // Bridge SwiftUI's navigation title, the sidebar toggle, and the
        // search field into the AppKit window's titlebar/toolbar.
        hostingController.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "settings.title", defaultValue: "Settings")
        window.setContentSize(NSSize(width: 980, height: 680))
        return window
    }
}

/// Root SwiftUI content of the AppKit-hosted Settings window. Applies the
/// environment the removed `Window` scene used to apply (settings runtime,
/// font magnification, appearance override) — an AppKit-hosted view does not
/// inherit the App scene's SwiftUI environment — and delivers any pending
/// navigation target once the content is live.
struct SettingsWindowHostRoot: View {
    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    var body: some View {
        content
            .cmuxFontMagnificationEnvironment()
            .cmuxAppearanceColorScheme(appearanceMode)
            .onAppear {
                guard let target = SettingsWindowPresenter.consumePendingNavigationTarget() else {
                    return
                }
                // One main-actor hop so the content's own notification
                // subscriptions are in place before the request posts.
                Task { @MainActor in
                    SettingsNavigationRequest.post(target)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let runtime = AppDelegate.shared?.settingsRuntime {
            SettingsWindowRoot(runtime: runtime)
                .settingsRuntime(runtime)
        } else {
            // Unreachable in a normally-launched app (the runtime is created
            // in cmuxApp.init before any UI); kept so a lifecycle regression
            // surfaces as a visible message instead of a silent no-op.
            Text(String(
                localized: "settings.window.runtimeUnavailable",
                defaultValue: "Settings could not load. Please restart cmux and report this issue."
            ))
            .padding(40)
            .frame(
                minWidth: SettingsWindowPresenter.minimumSize.width,
                minHeight: SettingsWindowPresenter.minimumSize.height
            )
        }
    }
}
