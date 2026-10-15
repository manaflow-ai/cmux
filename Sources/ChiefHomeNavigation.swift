import AppKit

extension Notification.Name {
    /// Shows Chief Home in a main window.
    ///
    /// Post with an `NSWindow` object to target that window; with no object the
    /// active main window (the one AppDelegate routes shortcuts to) is used.
    /// Shortcut, command palette, menu and CLI entrypoints all post this.
    static let cmuxOpenChiefHome = Notification.Name("cmux.chief.openHome")

    /// Toggles Chief Home in a main window: Home when showing a workspace, the
    /// workspace when showing Home. Same object rules as ``cmuxOpenChiefHome``.
    static let cmuxToggleChiefHome = Notification.Name("cmux.chief.toggleHome")

    /// Posted with the window as object after Chief Home became that window's content.
    ///
    /// Chief's Home view observes it and makes its compose field first responder.
    static let cmuxChiefHomeDidActivate = Notification.Name("cmux.chief.homeDidActivate")
}

/// Switches a main window between its workspaces and Chief Home.
///
/// One mutation path for every entrypoint: the sidebar Home row, the
/// notifications above, and workspace selection (which always leaves Home).
@MainActor
struct ChiefHomeNavigation {
    let sidebarSelectionState: SidebarSelectionState

    /// Shows Home. Nothing when `chief.enabled` is off.
    func open() {
        guard ChiefSettings.isEnabled, sidebarSelectionState.selection != .home else { return }
        sidebarSelectionState.selection = .home
    }

    /// Shows Home, or returns to the workspace when Home is already showing.
    func toggle() {
        if sidebarSelectionState.selection == .home {
            leave()
        } else {
            open()
        }
    }

    /// Returns to the workspace when Home is showing.
    func leave() {
        guard sidebarSelectionState.selection == .home else { return }
        sidebarSelectionState.selection = .tabs
    }

    /// Whether a Home notification addresses the window that owns `sidebarSelectionState`.
    static func notification(
        _ notification: Notification,
        targets window: NSWindow?,
        sidebarSelectionState: SidebarSelectionState
    ) -> Bool {
        if let target = notification.object as? NSWindow {
            return target === window
        }
        return AppDelegate.shared?.sidebarSelectionState === sidebarSelectionState
    }

    /// Moves keyboard focus after the selection changed.
    ///
    /// Entering Home takes focus away from the now-hidden workspace and hands it
    /// to Chief's compose field; leaving Home restores the workspace's focused
    /// panel. Called once per selection change, never from a key path.
    static func selectionDidChange(
        from oldValue: SidebarSelection,
        to newValue: SidebarSelection,
        window: NSWindow?,
        tabManager: TabManager,
        markHomeMounted: () -> Void
    ) {
        guard oldValue != newValue else { return }
        if newValue == .home {
            markHomeMounted()
            guard let window else { return }
            // Any workspace view (terminal, browser page, Markdown, a panel's
            // text field, portal-hosted or not) would keep typing while hidden.
            if homeMustTakeFocus(from: window.firstResponder, in: window, isHome: { $0 is ChiefHomeView }) {
                window.makeFirstResponder(nil)
            }
            // Next turn: on first entry Home's AppKit view joins the window
            // during this same update, after onChange runs.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                NotificationCenter.default.post(name: .cmuxChiefHomeDidActivate, object: window)
            }
        } else if oldValue == .home {
            tabManager.focusSelectedWorkspacePanel()
        }
    }

    /// Whether entering Home must take the keyboard from `responder`.
    ///
    /// Home covers the content area, so the workspace views of `window` are
    /// hidden behind it, including the terminal and browser views the window
    /// portals host above the SwiftUI content. Rather than list every panel
    /// kind, any view outside Home gives way (the sidebar too: the composer
    /// takes the keyboard right after). Only the window itself, a non-view
    /// responder, a view of another window and a view inside Home (`isHome`
    /// true for it or an ancestor) keep focus. A field editor counts as the
    /// text field it edits.
    static func homeMustTakeFocus(
        from responder: NSResponder?,
        in window: NSWindow,
        isHome: (NSView) -> Bool
    ) -> Bool {
        guard var view = responder as? NSView else { return false }
        if let editor = view as? NSTextView, editor.isFieldEditor, let edited = editor.delegate as? NSView {
            view = edited
        }
        guard view.window === window else { return false }
        var current: NSView? = view
        while let candidate = current {
            if isHome(candidate) { return false }
            current = candidate.superview
        }
        return true
    }
}
