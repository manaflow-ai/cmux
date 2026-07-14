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
    static let toolbarIdentifier = NSToolbar.Identifier("cmux.settings.toolbar")

    /// `onContentAppear` is invoked from the hosted content's `onAppear`, so
    /// the presenter that owns this window learns when the content's
    /// navigation consumer is installed (instance-scoped: never routed
    /// through the shared singleton, so test presenters using this real
    /// factory drain their own pending navigation).
    static func makeSettingsWindow(onContentAppear: @escaping @MainActor () -> Void) -> NSWindow {
        if AppDelegate.shared?.settingsRuntime == nil {
            // ``SettingsWindowHostRoot`` presents a visible, localized error
            // in this state — loud, never a silent no-op (issue #7777).
            log.fault("settings.window.factory settingsRuntime unavailable; presenting fallback content")
        }
        let hostingController = NSHostingController(
            rootView: SettingsWindowHostRoot(onContentAppear: onContentAppear)
        )
        // The AppKit owner configures the toolbar explicitly below; bridge only
        // SwiftUI's navigation title so an implicit scene toolbar can never
        // replace or remove the Settings chrome contract. The sidebar search
        // remains inside the hosted NavigationSplitView: `.searchable` with
        // `.sidebar` placement does not require toolbar bridging.
        hostingController.sceneBridgingOptions = [.title]
        let window = SettingsHostWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = String(localized: "settings.title", defaultValue: "Settings")
        configureChrome(on: window)
        window.setContentSize(NSSize(width: 980, height: 680))
        return window
    }

    /// Establishes the complete modern Settings chrome invariant at
    /// construction time. The AppKit-owned window must also own its toolbar;
    /// `sceneBridgingOptions` only forwards toolbar content explicitly declared
    /// by a hosted SwiftUI view and otherwise leaves a bare legacy titlebar.
    private static func configureChrome(on window: SettingsHostWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = window
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }
}

extension SettingsWindowPresenter {
    /// Routes the app's sidebar-toggle menu command (Toggle Left Sidebar) to
    /// the Settings split view when the Settings window is key. The AppKit-
    /// hosted window gets no SwiftUI `SidebarCommands`, so without this the
    /// command would toggle a terminal window's sidebar instead. Callers pass
    /// `NSApp.keyWindow`; a default argument would be evaluated outside the
    /// main actor and warn under strict concurrency.
    static func handleSidebarToggleIfSettingsWindowIsKey(keyWindow: NSWindow?) -> Bool {
        guard keyWindow?.identifier?.rawValue == windowIdentifier else { return false }
        requestSidebarToggle()
        return true
    }

    /// Shared mutation path for the toolbar item and the app's Toggle Left
    /// Sidebar command. The SwiftUI split view owns the visibility state and
    /// consumes this request in ``SettingsWindowRoot``.
    static func requestSidebarToggle(scope: String? = nil) {
        NotificationCenter.default.post(name: SettingsWindowRoot.sidebarToggleRequestName, object: scope)
    }
}

/// Settings window class that records the moment close teardown begins, so
/// ``SettingsWindowPresenter`` can deterministically refuse to reuse a dying
/// window even when a foreign `willClose` observer re-enters `show()` before
/// the presenter's own observer runs (notification-observer order is not a
/// lifecycle invariant).
class SettingsHostWindow: NSWindow, NSToolbarDelegate {
    private(set) var isClosingSettingsWindow = false

    /// Receives the standard AppKit toolbar item's `toggleSidebar:` action and
    /// forwards it through the same route as the app menu command.
    @objc func toggleSidebar(_ sender: Any?) {
        SettingsWindowPresenter.requestSidebarToggle()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // AppKit creates its standard toggle-sidebar item itself and does not
        // ask the delegate for it. No custom identifiers are allowed here.
        nil
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard
            let sidebarToggle = notification.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
            sidebarToggle.itemIdentifier == .toggleSidebar
        else { return }
        // AppKit may recreate standard items when the toolbar attaches to a
        // window. Configure every inserted instance so the live item always
        // uses the shared Settings toggle path.
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebar(_:))
    }

    override func close() {
        isClosingSettingsWindow = true
        super.close()
    }
}

/// Root SwiftUI content of the AppKit-hosted Settings window. Applies the
/// environment the removed `Window` scene used to apply (settings runtime,
/// font magnification, appearance override) — an AppKit-hosted view does not
/// inherit the App scene's SwiftUI environment — and delivers any pending
/// navigation target once the content is live.
struct SettingsWindowHostRoot: View {
    /// Readiness signal back to the presenter instance that owns this
    /// window. The presenter defers its pending-navigation post one
    /// main-actor hop (so the content's restore navigation cannot clobber
    /// it) and guards it against being superseded by a newer targeted show.
    let onContentAppear: @MainActor () -> Void

    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    var body: some View {
        content
            .cmuxFontMagnificationEnvironment()
            .cmuxAppearanceColorScheme(appearanceMode)
            .onAppear(perform: onContentAppear)
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
