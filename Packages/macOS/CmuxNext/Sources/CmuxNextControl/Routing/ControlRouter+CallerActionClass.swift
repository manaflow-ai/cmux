import CmuxNextSettings
import Foundation

/// What a caller's run with no target does, by action (``ControlRouter/callerClass(of:)``): every action of the
/// catalog is in exactly one class, and `CallerActionClassTests` runs each one of the app's real catalog through
/// `action.run` and fails for an action nobody classified.
enum CallerActionClass: String, Sendable, CaseIterable {
    /// Opens a tab that goes beside an agent caller: its helper column, else a new column right of it.
    case opensBeside
    /// Takes a tab, pane, screen or workspace: runs on the caller's own one.
    case ownPlace
    /// Closes, ends, archives, disconnects or destroys what it runs on: an agent must name that object, by a
    /// target or by the action's own argument.
    case closing
    /// Closes or puts away the workspaces or windows of one window and takes no target: with no window named it
    /// acts on the window the person has in front, so an agent must name the window, or cannot run it at all.
    case windowClosing
    /// Any other action (a setting, the palette, quit, an action on a machine or a bookmark that closes
    /// nothing): the caller changes nothing.
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

    /// The arguments that name a closing action's object and that its schema does not show as such
    /// (``objectArguments(of:)`` finds the rest): `cmux cloud archive-session --session S`.
    static let objectArgumentExceptions: [String: Set<String>] = ["cloud.team.archive": ["session"]]

    /// The class of `action`. The catalog decides where it can: a destructive action that takes a target is
    /// ``CallerActionClass/closing``, an action that takes a tab, pane, screen or workspace runs on the caller's
    /// own. The hand lists hold what it cannot say.
    static func callerClass(of action: ControlActionInfo) -> CallerActionClass {
        if windowClosingActions.contains(action.id) { return .windowClosing }
        if !action.targets.isEmpty, action.isDestructive || closingActions.contains(action.id) { return .closing }
        if opensBeside(action.id) { return .opensBeside }
        if action.id == "tabGroup.newTab" || action.targets.contains(where: { callerTargetKinds.contains($0) }) { return .ownPlace }
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

    /// Whether `request` names what `action` acts on: a target, or one of its ``objectArguments(of:)``.
    static func namesObject(_ request: ControlActionRequest, action: ControlActionInfo) -> Bool {
        request.target != nil || objectArguments(of: action).contains { request.arguments[$0] != nil }
    }

    /// Refuses an agent's closing or destructive run that does not name its object, before the run is aimed
    /// anywhere (the nearest browser, the caller's own place) and whatever kind of target the action takes. An
    /// agent is an agent session, any caller of the cmux MCP server (`origin: mcp`), or a terminal an agent runs
    /// in. A Chief turn acts for the person and is not refused; nor is a person's shell or a run with no caller
    /// (a key, a menu and the palette never send one: they call the registry, not the control socket).
    static func requireObjectOfAgentClosing(_ request: ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        let closing = callerClass(of: action)
        guard closing == .closing || closing == .windowClosing, !namesObject(request, action: action),
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
        throw ControlError(code: "target_required",
                           message: ControlStrings.format("control.error.agentMustNameObject",
                                                          "%1$@ closes or removes what it runs on, so an agent must name it; pass one of: %2$@",
                                                          action.id, names.joined(separator: ", ")),
                           data: ["action": .string(action.id), "targets": .array(action.targets.map(JSONValue.string)),
                                  "arguments": .array(objectArguments(of: action).map(JSONValue.string))])
    }
}
