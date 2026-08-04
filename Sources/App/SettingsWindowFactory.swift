import AppKit
import CmuxSettingsUI
import os

/// Builds the AppKit-owned Settings window
/// (https://github.com/manaflow-ai/cmux/issues/7777).
///
/// Construction is synchronous and infallible: unlike the previous scene-owned
/// `Window` scene + `openWindow(id:)` path, a call here always returns a real
/// `NSWindow`, so ``SettingsWindowPresenter`` can guarantee an open request
/// ends with a visible window.
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
            // The fallback controller presents a visible, localized error
            // in this state — loud, never a silent no-op (issue #7777).
            log.fault("settings.window.factory settingsRuntime unavailable; presenting fallback content")
        }
        let contentController: NSViewController
        if let runtime = AppDelegate.shared?.settingsRuntime {
            contentController = SettingsWindowRoot(
                runtime: runtime,
                onContentAppear: onContentAppear
            )
        } else {
            contentController = SettingsUnavailableViewController()
        }
        let window = SettingsHostWindow(contentViewController: contentController)
        // `.fullSizeContentView` lets the native split sidebar extend under the titlebar for the
        // full-height-sidebar look, while the titlebar itself stays at the
        // AppKit defaults (visible title, opaque titlebar, automatic
        // toolbar style and separator). Forcing any of those away from
        // the defaults is what produced the #8015 hybrid chrome.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = String(localized: "settings.title", defaultValue: "Settings")
        // [flexible space, sidebar toggle, sidebar tracking separator] is the
        // native split-view item layout: the toggle sits at the sidebar's
        // trailing edge and the title renders bold at the detail column's
        // leading edge.
        window.toolbar = window.sidebarToolbarController.makeToolbar()
        window.setContentSize(NSSize(width: 980, height: 680))
        return window
    }
}

/// AppKit-owned sidebar toggle. The toggle posts the same
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
    /// hosted window has its own sidebar owner, so without this the command
    /// would toggle a terminal window's sidebar instead. Callers pass
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

@MainActor
private final class SettingsUnavailableViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: String(
            localized: "settings.window.runtimeUnavailable",
            defaultValue: "Settings could not load. Please restart cmux and report this issue."
        ))
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(label)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsWindowPresenter.minimumSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsWindowPresenter.minimumSize.height),
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
        ])
        view = root
    }
}
