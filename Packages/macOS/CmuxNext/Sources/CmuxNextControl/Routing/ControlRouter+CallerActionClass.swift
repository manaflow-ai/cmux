import CmuxNextSettings
import Foundation

/// What a caller's run with no target does, by action (``ControlRouter/callerClass(of:)``): every action of the
/// catalog is in exactly one class, and `CallerActionClassTests` runs each one of the app's real catalog through
/// `action.run` and fails for an action nobody classified.
enum CallerActionClass: String, Sendable, CaseIterable {
    /// Opens a tab that goes beside an agent caller: its helper column, else a new column right of it.
    case opensBeside
    /// Takes a tab, pane, screen or workspace, or a group of one: runs on the caller's own one, or on the group
    /// its own tab, screen or workspace is in.
    case ownPlace
    /// Closes, ends, archives, disconnects or destroys what it runs on: an agent must name that object, by a
    /// target or by the action's own argument.
    case closing
    /// Acts on something of the window the person has in front when nothing is named, and a caller has none of
    /// its own: that window, its workspaces, its Chief, its Space, the bookmark of its page. An agent must name
    /// the object, or cannot run the action at all when it takes nothing to name.
    case personsFront
    /// Any other action (a setting, a page or the palette, quit, an action on a machine): the caller changes
    /// nothing. Where a page or a palette shows is the view-change rule's (`ActionRunScope.allowsViewChange`).
    case unaffected
}

extension ControlRouter {
    /// The target kinds a caller has of its own, in no order: an action lists its own first.
    static let callerTargetKinds: Set<String> = ["tab", "pane", "screen", "workspace"]

    /// Actions that close, end, archive, disconnect or put away what they act on and that the catalog does not
    /// mark destructive.
    static let closingActions: Set<String> = [
        // Tabs.
        "closeTab", "closeOtherTabsInPane", "closeTabsToLeft", "closeTabsToRight", "disconnectRemoteTab", "hibernateTab",
        "macScreen.stopViewing", "tab.restart", "tab.stash", "tab.stashOthers", "tab.stashToRight",
        // Panes and what they show.
        "closePane", "pane.closeOthers", "agentPane.archiveChat", "agentPane.stopTurn", "agentPane.permission.revoke",
        "browser.pageInfo.resetPermissions", "palette.vscodeServeWebStop", "palette.vscodeServeWebRestart",
        // Screens, workspaces and their groups.
        "screen.close", "disconnectWorkspace", "cloud.team.archive", "workspace.hibernate", "workspace.toggleArchive",
        "workspace.archiveOtherWorkspaces", "workspace.archiveOthersInGroup", "workspace.archiveWorkspacesBelow",
        "workspace.archiveWorkspacesAbove", "workspaceGroup.toggleArchive",
        // Sidebar rows, machines, bookmarks.
        "sidebar.item.remove", "sidebar.item.removeEverywhere", "sidebar.item.toggleArchive", "remote.disconnect",
        "remote.removeGroup", "cloudPauseMachine", "cloudPortClose", "cloudPreviewRevoke", "machine.joined.revoke", "bookmark.remove",
    ]

    /// Actions with no target kind that close, merge away or trash something of one window: its workspaces, the
    /// other windows, the file its file explorer has selected. They act on the named window (`window`, where
    /// the action takes it), else on the window the person has in front (`AppActionContext.window`). Close All
    /// Windows, Close All Workspaces in All Windows and Quit name everything and guess no window: they are
    /// ``CallerActionClass/unaffected``.
    static let windowClosingActions: Set<String> = [
        "workspace.closeAll", "window.stash", "closeWindow", "window.closeOthers", "window.mergeAll", "fileExplorerMoveToTrash",
    ]

    /// Actions with no target kind whose handler changes the window the person has in front, or its Chief
    /// (`windows.active`, `AppActionContext.window`, the key window's Home): its size, its sidebar, its Space,
    /// its Chief's turn. A Chief turn (`caller.home_chat`) is never refused: Stop Chief and Stop All Agents
    /// from it stop its own Chief. The cmux CLI refuses both for every agent before any request
    /// (`origin.forbidden`, docs/cli-contract.md); this is the same rule for a request that names its caller.
    static let frontWindowActions: Set<String> = [
        "minimizeWindow", "toggleFullScreen", "toggleSidebar", "focusSidebar", "space.selectByNumber", "home.stopChief", "home.stopAllAgents",
    ]

    /// The target kinds a caller has none of and whose resolver takes the front window's one when the run names
    /// none (`AppActionContext.window`, the active window's Space, the focused page's bookmark): a window, a
    /// Space (`room`), a bookmark.
    static let frontKinds: Set<String> = ["window", "room", "bookmark"]

    /// Actions of a ``frontKinds`` kind that only read the front object: an agent's screenshot of the window is
    /// how it checks the app, and changes nothing of the person's.
    static let frontReadingActions: Set<String> = ["window.screenshot"]

    /// The caller's own place for an action on a group: the handlers read the group of the run's tab, screen or
    /// workspace when no group is named (`TabGroupHandlers.group`, `screenGroup`, `personalGroup`). A caller whose
    /// own one is in no group gets the action's own refusal.
    static let groupPlaceKinds: [String: String] = ["tabgroup": "tab", "screengroup": "screen", "workspacegroup": "workspace"]

    /// Actions that take no target kind and whose handler still reads the run's tab, pane or workspace
    /// (`ActionScope`, `AppActionContext.paneController`), the focused one with no target: with a caller they
    /// run on its own.
    static let ownPlaceByHand: [String: String] = [
        "toggleUnread": "tab", "palette.toggleTerminalChat": "tab", "appearance.changeBackground": "workspace",
        "agentHistory.show": "pane", "diagnostics.viewHangReport": "pane", "browserProfile.manageExtensions": "pane",
        "remote.openBrowserTab": "pane", "remote.openLocalBrowserTab": "pane",
    ]

    /// The kind of its own place a caller's run of `action` with no target is aimed at: the action's first tab,
    /// pane, screen or workspace kind, else the one its group kind stands for, else ``ownPlaceByHand``; nil: none.
    static func callerPlaceKind(of action: ControlActionInfo) -> String? {
        if let own = action.targets.first(where: { callerTargetKinds.contains($0) }) { return own }
        return action.targets.lazy.compactMap { groupPlaceKinds[normalizedKind($0)] }.first ?? ownPlaceByHand[action.id]
    }

    /// The arguments that name a closing action's object and that its schema does not show as such
    /// (``objectArguments(of:)`` finds the rest): `cmux cloud archive-session --session S`.
    static let objectArgumentExceptions: [String: Set<String>] = ["cloud.team.archive": ["session"]]

    /// The class of `action`. The catalog decides where it can: a destructive action that takes a target is
    /// ``CallerActionClass/closing``, an action that takes a tab, pane, screen or workspace (or a group of one)
    /// runs on the caller's own, one that takes a window, a Space or a bookmark acts on the person's front one.
    /// The hand lists hold what it cannot say.
    static func callerClass(of action: ControlActionInfo) -> CallerActionClass {
        if windowClosingActions.contains(action.id) || frontWindowActions.contains(action.id) { return .personsFront }
        if !action.targets.isEmpty, action.isDestructive || closingActions.contains(action.id) { return .closing }
        if opensBeside(action.id) { return .opensBeside }
        if callerPlaceKind(of: action) != nil { return .ownPlace }
        if action.targets.contains(where: { frontKinds.contains(normalizedKind($0)) }), !frontReadingActions.contains(action.id) { return .personsFront }
        return .unaffected
    }

    /// The arguments of `action` that name the object it acts on: a target argument the run's target supplies, or
    /// one of a kind the action does not take as its target (Close All Workspaces' `window`, Clear History's
    /// `browserProfile`; not Delete Space's `moveTo`, a space like its target); a text argument named as one of
    /// the action's target kinds (Remove Bookmark's `bookmark`); and ``objectArgumentExceptions``.
    static func objectArguments(of action: ControlActionInfo) -> [String] {
        let kinds = Set(action.targets.map(normalizedKind))
        return action.arguments.filter { argument in
            if objectArgumentExceptions[action.id]?.contains(argument.name) == true { return true }
            switch argument.kind {
            case .target: return argument.isSuppliedByTarget || !kinds.contains(normalizedKind(argument.targetKind ?? ""))
            case .string: return kinds.contains(normalizedKind(argument.name))
            case .int, .bool, .enumeration: return false
            }
        }.map(\.name)
    }

    /// Whether `request` names what `action` acts on: a target, or one of its ``objectArguments(of:)`` with a
    /// value that names something. An empty or blank text names nothing (`--session ""` archived the agent's own
    /// session, as no `--session` did), nor does a target with no id or a flag.
    static func namesObject(_ request: ControlActionRequest, action: ControlActionInfo) -> Bool {
        request.target != nil || objectArguments(of: action).contains { name in
            switch request.arguments[name] {
            case .string(let text)?: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .target(let ref)?: !ref.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .int?: true
            case .bool?, nil: false
            }
        }
    }

    /// Refuses an agent's run that closes or destroys, or that acts on the person's front window, Space or
    /// bookmark, and does not name its object, before the run is aimed
    /// anywhere (the nearest browser, the caller's own place) and whatever kind of target the action takes. An
    /// agent is an agent session, any caller of the cmux MCP server (`origin: mcp`), or a terminal an agent runs
    /// in. A Chief turn acts for the person and is not refused; nor is a person's shell or a run with no caller
    /// (a key, a menu and the palette never send one: they call the registry, not the control socket).
    static func requireObjectOfAgentClosing(_ request: ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        let actionClass = callerClass(of: action)
        guard actionClass == .closing || actionClass == .personsFront, !namesObject(request, action: action),
              let caller = request.caller, !caller.homeChat else { return }
        guard caller.agentSession != nil || caller.viaMCP
            || ControlCallerLocation.resolve(caller, in: topology).map({ ControlCallerPlacement($0).isBeside }) == true else { return }
        // What to pass for this action. Never the caller's own tab or workspace: for Close Tab or Archive
        // Session that names the agent's own home.
        let names = action.targets.map { "target \($0):<id>" } + objectArguments(of: action).map { "--\($0) <value>" }
        guard !names.isEmpty else {
            throw ControlError(code: "person_required",
                               message: ControlStrings.format("control.error.agentCannotNameWindow",
                                                              "%@ acts on the window the person has in front and takes no window to name, so an agent cannot run it",
                                                              action.id),
                               data: ["action": .string(action.id)])
        }
        let message = actionClass == .closing
            ? ControlStrings.format("control.error.agentMustNameObject",
                                    "%1$@ closes or removes what it runs on, so an agent must name it; pass one of: %2$@",
                                    action.id, names.joined(separator: ", "))
            : ControlStrings.format("control.error.agentMustNameFront",
                                    "%1$@ acts on what the person has in front when nothing is named, so an agent must name it; pass one of: %2$@",
                                    action.id, names.joined(separator: ", "))
        throw ControlError(code: "target_required", message: message,
                           data: ["action": .string(action.id), "targets": .array(action.targets.map(JSONValue.string)),
                                  "arguments": .array(objectArguments(of: action).map(JSONValue.string))])
    }
}
