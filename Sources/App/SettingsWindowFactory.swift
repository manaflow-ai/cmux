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
        // Bridge only the navigation title. `.toolbars` is deliberately
        // absent: the scene bridge never materializes NavigationSplitView's
        // implicit sidebar toggle in an AppKit-hosted window, so the factory
        // owns the toolbar below instead.
        hostingController.sceneBridgingOptions = [.title]
        let window = SettingsHostWindow(contentViewController: hostingController)
        // Match the chrome SwiftUI applies to its own `WindowGroup` window
        // (the 0.64.17 Settings scene): `.fullSizeContentView` lets the
        // NavigationSplitView sidebar extend under the titlebar for the
        // full-height-sidebar look, while the titlebar itself stays at the
        // AppKit defaults (visible title, opaque titlebar, automatic
        // toolbar style and separator). Forcing any of those away from
        // the defaults is what produced the #8015 hybrid chrome.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = String(localized: "settings.title", defaultValue: "Settings")
        // [flexible space, sidebar toggle, sidebar tracking separator] is the
        // exact item layout the SwiftUI-owned 0.64.17 window built for its
        // NavigationSplitView: the toggle sits at the sidebar's trailing edge
        // and the title renders bold at the detail column's leading edge.
        window.toolbar = window.sidebarToolbarController.makeToolbar()
        window.setContentSize(NSSize(width: 980, height: 680))
        return window
    }
}

/// AppKit-owned replacement for the sidebar toggle the SwiftUI `WindowGroup`
/// scene provided implicitly in 0.64.17. The toggle posts the same
/// notification the app's Toggle Left Sidebar menu command routes to the
/// Settings window, so both entrypoints share one `columnVisibility`
/// mutation path in ``SettingsWindowRoot``.
@MainActor
final class SettingsSidebarToolbarController: NSObject, NSToolbarDelegate {
    static let toggleSidebarItemIdentifier = NSToolbarItem.Identifier("cmux.settings.toggleSidebar")

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "cmux.settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toggleSidebarItemIdentifier, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.toggleSidebarItemIdentifier else { return nil }
        let label = String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Toggle Left Sidebar")
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
        item.label = label
        item.toolTip = String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")
        item.target = self
        item.action = #selector(requestSidebarToggle(_:))
        return item
    }

    @objc private func requestSidebarToggle(_ sender: Any?) {
        NotificationCenter.default.post(name: SettingsWindowRoot.sidebarToggleRequestName, object: nil)
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
        NotificationCenter.default.post(name: SettingsWindowRoot.sidebarToggleRequestName, object: nil)
        return true
    }
}

/// Settings window class that records the moment close teardown begins, so
/// ``SettingsWindowPresenter`` can deterministically refuse to reuse a dying
/// window even when a foreign `willClose` observer re-enters `show()` before
/// the presenter's own observer runs (notification-observer order is not a
/// lifecycle invariant).
class SettingsHostWindow: NSWindow {
    private(set) var isClosingSettingsWindow = false

    /// Retains the toolbar delegate for the window's lifetime
    /// (`NSToolbar.delegate` is unretained).
    let sidebarToolbarController = SettingsSidebarToolbarController()

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
