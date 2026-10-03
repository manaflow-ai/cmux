import AppKit
import CmuxNextActions
import CmuxNextDesign

/// What a user run of an action does while a window of a kind is key
/// (plans/cmux-next/windows.md, "One keyboard table").
nonisolated enum WindowKeyBehavior: Equatable, Sendable {
    /// The action runs as usual (against the last main window's focus).
    case run
    /// Close the root window (`performClose`, so its delegate may decline,
    /// as with its close button).
    case closeWindow
    /// Nothing runs and nothing beeps: a sheet or panel over a window of
    /// its own got a close shortcut.
    case consume
    /// The menu item is off and a run is refused with the reason.
    case disabled(reason: String)
}

/// The one table of what each action means in each ``WindowKind``. It runs
/// in the registry before availability, confirmation and the handler
/// (`ActionRegistry.keyWindowRoute`), and menu validation asks it too, so
/// the keyboard, the menu bar and the palette agree.
///
/// Rows: a main window (`WindowCloseSemantics.contentFirst`) runs
/// everything. Every other kind: close actions (catalog ids whose last
/// segment starts with `close`) close the window; app-level actions run;
/// destructive actions on main window content (their targets include a
/// tab, pane, workspace, screen, group, column or window) are disabled,
/// because they would change state the user cannot see; the rest run
/// against the last main window (Cmd-T in Settings opens a tab there).
///
/// Before, handlers resolved "the focused object" through the last main
/// window, so Cmd-W in Debug Settings closed a tab of the main window
/// behind it.
struct WindowKeyTable {
    /// Actions that belong to the app, not to the window that is key.
    static let appLevel: Set<ActionID> = [
        "quit", "quitKeepSessions", "quitEndSessions", "quitEndEverything", "newWindow", "newIncognitoWindow",
        "openSettings", "openDebugSettings", "commandPalette", "showHideAllWindows", "about", "appStore.show",
    ]

    /// Target kinds that live in a main window.
    static let contentTargets: Set<ActionTargetKind> = [
        .tab, .pane, .workspace, .workspaceGroup, .screen, .screenGroup, .tabGroup, .column, .window,
    ]

    let registry: ActionRegistry

    /// A close action: its id's last segment starts with `close`
    /// (`closeTab`, `palette.closeOtherWorkspaces`, `tabGroup.close`).
    static func isClose(_ id: ActionID) -> Bool {
        let last = id.rawValue.split(separator: ".").last ?? ""
        return last.hasPrefix("close")
    }

    /// Destructive, and acts on main window content.
    func destroysContent(_ id: ActionID) -> Bool {
        guard let descriptor = registry.descriptor(for: id) else { return false }
        return descriptor.isDestructive && !Self.contentTargets.isDisjoint(with: descriptor.targets)
    }

    /// The behavior of `id` while a window of `kind` is key. `overRoot`:
    /// the key window is a sheet or panel over that window, not the window
    /// itself.
    func behavior(for id: ActionID, in kind: WindowKind, overRoot: Bool = false) -> WindowKeyBehavior {
        behavior(for: id, close: kind.traits.close, overRoot: overRoot)
    }

    /// The row for a window by its close semantics (a window no owner
    /// installed through the window kit acts as a window of its own).
    func behavior(for id: ActionID, close: WindowCloseSemantics, overRoot: Bool = false) -> WindowKeyBehavior {
        guard close == .window else { return .run }
        if Self.isClose(id) { return overRoot ? .consume : .closeWindow }
        if Self.appLevel.contains(id) { return .run }
        if destroysContent(id) { return .disabled(reason: MiscHandlerStrings.noPane) }
        return .run
    }

    /// Whether `invocation` names its object (target or object argument):
    /// a targeted run (a context menu, the CLI) means that object wherever
    /// the keyboard is.
    static func hasTarget(_ invocation: ActionInvocation) -> Bool {
        invocation.target != nil
            || ["tab", "pane", "workspace", "window", "group"].contains { invocation[$0]?.targetValue != nil }
    }

    /// Installs the table behind the registry's key window hook.
    static func install(_ services: AppServices) {
        let table = WindowKeyTable(registry: services.registry)
        services.registry.keyWindowRoute = { [weak services] id, invocation in
            // Automation and targeted runs never look at the key window.
            guard let services, invocation.origin == .user, !hasTarget(invocation),
                  let key = services.keyWindowRole else { return nil }
            switch table.behavior(for: id, close: key.close, overRoot: key.overRoot) {
            case .run: return nil
            case .closeWindow: return .run { [weak root = key.root] in root?.performClose(nil) }
            case .consume: return .run {}
            case .disabled(let reason): return .disabled(reason: reason)
            }
        }
    }
}

extension AppServices {
    /// The window the key window acts for, its close semantics, and
    /// whether the key window is a sheet or panel over it. Nil when there
    /// is no key window of ours: a parentless Chromium page window, or a
    /// borderless panel no window owns.
    ///
    /// The kind comes from the window kit (`NSWindow.windowKindRoot`). A
    /// window no owner installed acts as a main window when a main window
    /// owns it (palette, sheets), else as a window of its own when its
    /// root is titled and closable.
    var keyWindowRole: (root: NSWindow, close: WindowCloseSemantics, overRoot: Bool)? {
        guard let key = keyWindowSource() else { return nil }
        let root = key.windowKindRoot
        // A Chromium page window inside the root (an undocked inspector's
        // page, a popup's page) acts for it.
        let inside = key === root || (key.sheetParent == nil && Self.isChromiumPageWindow(key))
        if let kind = root.windowKind { return (root, kind.traits.close, !inside) }
        if windows.owner(of: key) != nil { return (root, .contentFirst, !inside) }
        if root === key, Self.isChromiumPageWindow(key) { return nil }
        guard root.styleMask.isSuperset(of: [.titled, .closable]) else { return nil }
        return (root, .window, !inside)
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}
