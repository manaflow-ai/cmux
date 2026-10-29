import AppKit
import CmuxHomeCore

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

/// Selects Chief's persistent workspace through the native workspace navigation path.
/// Shortcut, command palette, menu and CLI actions all resolve the same Home anchor.
@MainActor
struct ChiefHomeNavigation {
    static let homeGroupExternalID = "cmux.chief.home"

    let sidebarSelectionState: SidebarSelectionState
    let tabManager: TabManager

    /// Selects the ordinary Home workspace through the same path as every workspace row.
    func open() {
        guard let home = Self.ensureHome(in: tabManager) else { return }
        sidebarSelectionState.selection = .tabs
        tabManager.selectWorkspace(home)
        if let chief = home.panels.values.compactMap({ $0 as? ChiefPanel }).first(where: \.isHome) {
            home.focusPanel(chief.id)
        }
    }

    func toggle() {
        if tabManager.selectedWorkspace?.isChiefHome == true,
           let other = tabManager.tabs.first(where: { !$0.isChiefHome }) {
            sidebarSelectionState.selection = .tabs
            tabManager.selectWorkspace(other)
        } else {
            open()
        }
    }

    /// Clears the legacy page selection without changing the workspace's editable layout.
    func leave() {
        if sidebarSelectionState.selection == .home { sidebarSelectionState.selection = .tabs }
    }

    /// Home is a persistent native workspace and group anchor, never a covering page.
    @discardableResult
    static func ensureHome(in manager: TabManager) -> Workspace? {
        guard ChiefSettings.isEnabled, !manager.isFinalizedForWindowClose else { return nil }
        let home: Workspace
        if let existing = manager.tabs.first(where: \.isChiefHome) {
            home = existing
        } else {
            guard let created = makeWorkspace(in: manager, title: ChiefStrings.home, isHome: true) else { return nil }
            home = created
        }
        if home.customTitle != ChiefStrings.home {
            manager.setCustomTitle(tabId: home.id, title: ChiefStrings.home, source: .user)
        }
        let groupID: UUID
        if let group = manager.workspaceGroups.first(where: { $0.externalID == homeGroupExternalID }) {
            groupID = group.id
            if group.anchorWorkspaceId != home.id {
                manager.addWorkspaceToGroup(workspaceId: home.id, groupId: groupID)
                manager.setWorkspaceGroupAnchor(groupId: groupID, workspaceId: home.id)
            }
        } else {
            guard let created = manager.createWorkspaceGroup(
                name: ChiefStrings.home,
                childWorkspaceIds: [home.id],
                selectAnchor: false,
                collapseSidebarSelection: false,
                externalID: homeGroupExternalID
            ) else { return home }
            groupID = created
        }
        if let group = manager.workspaceGroups.first(where: { $0.id == groupID }) {
            if group.name != ChiefStrings.home {
                manager.renameWorkspaceGroup(groupId: groupID, name: ChiefStrings.home)
            }
            if !group.isPinned { manager.setWorkspaceGroupPinned(groupId: groupID, isPinned: true) }
            if group.iconSymbol != "house" { _ = manager.setWorkspaceGroupIcon(groupId: groupID, symbol: "house") }
        }
        if manager.tabs.first?.id != home.id {
            manager.moveWorkspaceGroup(groupId: groupID, toIndex: 0)
        }
        return home
    }

    /// Selects a conversation in the canonical Home pane.
    @discardableResult
    static func openConversation(_ id: ConversationID, in manager: TabManager, select: Bool = true) -> Workspace? {
        guard let home = ensureHome(in: manager) else { return nil }
        if let chief = home.panels.values.compactMap({ $0 as? ChiefPanel }).first(where: \.isHome) {
            chief.conversationID = id
        }
        if select {
            manager.selectWorkspace(home)
            if let chief = home.panels.values.compactMap({ $0 as? ChiefPanel }).first(where: \.isHome) {
                home.focusPanel(chief.id)
            }
        }
        return home
    }

    /// Plus in Home and New Conversation in Chief Settings share this action.
    static func newConversation(in manager: TabManager) {
        // task-owner: one create operation, ending with its reply; no process starts here.
        Task { @MainActor [weak manager] in
            do {
                let id = try await ChiefService.shared.createConversation()
                guard let manager, !manager.isFinalizedForWindowClose else { return }
                _ = openConversation(id, in: manager)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// The workspace a window opens on: `candidate`, unless it is Home, then
    /// the first other workspace (Home when it is the only one).
    static func openingWorkspace(_ candidate: Workspace?, in tabs: [Workspace]) -> Workspace? {
        guard let candidate, candidate.isChiefHome else { return candidate }
        return tabs.first { !$0.isChiefHome } ?? candidate
    }

    /// Moves a window that shows Home onto a terminal, creating a terminal
    /// workspace when Home is the only one. Runs right after a window's
    /// session restore, never later: a `cmux chief open` sent at launch
    /// selects Home on purpose and must not be undone.
    static func openOnTerminal(in manager: TabManager) {
        guard manager.selectedWorkspace?.isChiefHome == true else { return }
        if let other = openingWorkspace(manager.selectedWorkspace, in: manager.tabs), !other.isChiefHome {
            manager.selectWorkspace(other)
        } else {
            _ = manager.addWorkspaceIfActive(select: true, autoWelcomeIfNeeded: false)
        }
    }

    /// Whether a main window makes Home when it appears. Not in a test host: its
    /// windows stand for plain cmux windows, and Chief tests call ``ensureHome(in:)``.
    static func makesHomeWhenAWindowAppears(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !MacSentryStartupPolicy.isRunningUnderXCTest(environment: environment)
    }

    /// Ensures the canonical Home workspace exists. Conversations are loaded by
    /// the list inside that pane rather than materialized as sidebar workspaces.
    static func restoreConversations(in manager: TabManager) {
        guard let home = ensureHome(in: manager) else { return }
        manager.removeLegacyChiefConversationWorkspaces(in: home)
    }

    private static func makeWorkspace(
        in manager: TabManager,
        title: String,
        conversationID: ConversationID? = nil,
        isHome: Bool = false
    ) -> Workspace? {
        guard let workspace = manager.addWorkspaceIfActive(
            title: title,
            titleSource: isHome ? .user : .auto,
            inheritWorkingDirectory: false,
            select: false,
            initialTerminalStartsOnFirstVisit: true,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        ), let pane = workspace.bonsplitController.focusedPaneId else { return nil }
        let scaffold = Array(workspace.panels.keys)
        guard workspace.newChiefSurface(
            inPane: pane, conversationID: conversationID, isHome: isHome, focus: false
        ) != nil else {
            manager.closeWorkspace(workspace, recordHistory: false)
            return nil
        }
        workspace.withClosedPanelHistorySuppressed {
            for panelID in scaffold { _ = workspace.closePanel(panelID, force: true) }
        }
        return workspace
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
