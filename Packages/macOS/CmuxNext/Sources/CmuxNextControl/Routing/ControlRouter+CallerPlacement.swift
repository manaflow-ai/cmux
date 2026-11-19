import CmuxNextSettings
import Foundation

/// `action.run` for a run that names a caller and no target (``ControlCallerPlacement``): the run uses the
/// caller's own place, never the app's focus. The one owner of that rule: `file.open`, `browser.open_split`,
/// `browser.page.right` and `browser.page.new_tab` hand their runs here with the caller.
///
/// - What an agent opens beside itself (``opensBeside(_:)``: a browser of any engine, the diff viewer, a file,
///   a new terminal or tab) goes in its helper column, else in a new column right of its pane. A terminal no
///   agent runs in keeps it in its own pane.
/// - Any other action that takes a tab, pane or workspace target runs on the caller's own tab, pane or workspace
///   (a rename renames its own workspace). That includes the opens that name their own place (``opensSurface(_:)``:
///   New ▸ kind ▸ place, Split Right, Mac Screen, Reopen Closed Tab): they open in the caller's own pane, as asked.
/// - An agent's run that closes or destroys (``closingActions``, the catalog's destructive actions) is refused
///   until it names its target (``requireTargetOfAgentClosing``, before anything is aimed): for an agent, "this
///   tab" may be its own home, the tab it opened last, or the nearest browser, and the wrong guess ends the
///   agent or loses the person's work. That holds for every action that takes a target of any kind (a screen,
///   a tab group, a machine, a bookmark too: with none they act on what the person has focused or selected). A
///   person's shell keeps its own tab, pane, screen or workspace, which is what its focused run meant.
/// - A browser from a terminal is aimed at the terminal's own tab; the app sends it where a Cmd-click's goes.
/// - An agent whose chat no tab shows stands in the workspace its session runs in (`caller.workspace`): what it
///   opens is placed from there and a workspace run is that workspace; it has no tab or pane of its own, so any
///   other run is refused. An agent cmux cannot place at all is refused (`caller_unavailable`), never run on the
///   focused pane, which is Home while the person talks to the Chief (user, 2026-11-18); only
///   ``workspaceCreatingActions`` still run.
/// - A Chief turn (`caller.home_chat`) acts for the person across the app: only what it opens beside itself is
///   placed, beside the Home chat; its other runs are unchanged.
/// - An action with no such target kind (settings, the palette) and a run with a target or no caller are unchanged.
///
/// Existing-browser actions are aimed first, at the browser nearest the caller (``aimBrowserActionAtCaller``).
extension ControlRouter {
    /// The actions, with the browser (``opensBrowser(_:)``), whose handlers place the new tab beside an agent
    /// caller (AgentBesidePlacement): selected in its helper column, or moved into a new column right of it.
    static let besideCallerActions: Set<String> = [
        "openDiffViewer", "file.open", "openMarkdownFile", "newSurface", "newTab.default", "newTab.ofKind",
    ]

    /// `openBrowser` and its engine variants (`openBrowser.webkit`, `openBrowser.chromium`).
    static func opensBrowser(_ id: String) -> Bool { id == "openBrowser" || id.hasPrefix("openBrowser.") }

    /// Whether `id` opens a tab that goes beside an agent caller.
    static func opensBeside(_ id: String) -> Bool { opensBrowser(id) || besideCallerActions.contains(id) }

    /// The kind the same-kind rule reads for what `id` opens (`browser`, `terminal`); nil: no kind.
    static func besideKind(_ id: String) -> String? { opensBrowser(id) ? "browser" : id == "newSurface" ? "terminal" : nil }

    /// The other actions that open a new tab or page where their target is: run by an agent with
    /// no target they open in the agent's own place, never in the focused pane. A new workspace or
    /// window (`newTab`, `newWindow`) is not one: it opens no tab in an existing workspace.
    static func opensSurface(_ id: String) -> Bool {
        ["new.", "newSurface", "tabGroup.newTab", "file.open", "macScreen.open", "reopenClosedBrowserPanel"].contains { id.hasPrefix($0) }
    }

    /// The target kinds a caller has of its own, in no order: an action lists its own first.
    static let callerTargetKinds: Set<String> = ["tab", "pane", "screen", "workspace"]

    /// Actions that close, end, archive, disconnect or put away what they act on and that the catalog does not
    /// mark destructive. `AgentClosingActionsTests` walks the real catalog: an action whose name says it closes
    /// something and that takes a target must be here, destructive, or listed there as judged safe.
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
        "remote.removeGroup", "cloudPortClose", "cloudPreviewRevoke", "machine.joined.revoke", "bookmark.remove",
    ]

    /// Whether `action` closes or destroys the place it runs on: the catalog's destructive actions and
    /// ``closingActions``, when the action takes a target (one with no target kind is global: settings, quit).
    static func closesItsPlace(_ action: ControlActionInfo) -> Bool {
        !action.targets.isEmpty && (action.isDestructive || closingActions.contains(action.id))
    }

    /// Refuses an agent's closing or destructive run that names no target, before the run is aimed anywhere
    /// (the nearest browser, the caller's own place) and whatever kind of target the action takes. An agent is
    /// an agent session, any caller of the cmux MCP server (`origin: mcp`), or a terminal an agent runs in. A
    /// Chief turn acts for the person and is not refused; nor is a person's shell or a run with no caller.
    static func requireTargetOfAgentClosing(_ request: ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        guard request.target == nil, closesItsPlace(action), let caller = request.caller, !caller.homeChat else { return }
        let location = ControlCallerLocation.resolve(caller, in: topology)
        guard caller.agentSession != nil || caller.viaMCP || location.map({ ControlCallerPlacement($0).isBeside }) == true else { return }
        // Its own ids to choose from, when a tab shows it; else there is nothing of its own to name.
        guard let location, location.isOwnTab else { throw Self.callerNotLocated(caller, action: action) }
        throw Self.targetRequired(action, location: location)
    }

    /// Actions that make a workspace and take a workspace target only as the place of its sidebar row: an agent
    /// with no chat or terminal of its own (a session no tab shows) still runs them.
    static let workspaceCreatingActions: Set<String> = [
        "newTab", "newBrowserWorkspace", "openFolder", "palette.openFolderInVSCodeInline", "palette.layout.open",
        "workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom", "workspace.newInNewGroup",
        "workspace.newOnMachine", "newWorkspaceGroup", "reopenClosedWorkspace", "reopenPreviousSession",
    ]

    /// Aims a run that names a caller and no target at the caller's own place. An agent cmux cannot place is
    /// refused (it has no place, and the focused pane is never its place); a terminal the topology does not show
    /// is another session's, and its run is left as it is.
    static func placeAtCaller(_ request: inout ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        guard let caller = request.caller else { return }
        guard request.target == nil else {
            // An explicit target wins. A terminal's browser aimed at its own tab (an older CLI's `browser open`)
            // still goes where a Cmd-click's would (TabLifecycle): it is told which panes are another agent's.
            if opensBrowser(action.id), caller.terminalID != nil, let location = ControlCallerLocation.resolve(caller, in: topology) {
                request.besideAgentHomes = ControlCallerPlacement(location).agentHomes
            }
            return
        }
        // Open in the editor app opens nothing in cmux: there is no place to choose.
        if action.id == "file.open", request.arguments["where"] == .string("editor") { return }
        let beside = opensBeside(action.id), opens = beside || opensSurface(action.id)
        var kind = action.targets.first { callerTargetKinds.contains($0) }
        // New Tab in Group takes a tab group: the group of the caller's own tab (its handler reads a tab's group).
        if kind == nil, action.id == "tabGroup.newTab" { kind = "tab" }
        guard beside || (kind != nil && !caller.homeChat) else { return }
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            guard caller.agentSession != nil || caller.homeChat else { return }
            if opens { throw BrowserCallerTarget.missingCaller(caller) }
            // Before the first topology (the app starts) nothing can be located: the handler decides, as before.
            guard topology.isLoaded, !workspaceCreatingActions.contains(action.id) else { return }
            throw Self.callerNotLocated(caller, action: action)
        }
        let placement = ControlCallerPlacement(location)
        request.besideAgentHomes = placement.agentHomes
        // A browser from a terminal a window shows, an agent's or a person's, goes where a Cmd-click's would
        // (TabLifecycle, Lawrence 2026-11-15): the run is aimed at the terminal's own tab, and the app picks the
        // pane on its right, else a new pane beside it, never one of another agent (`besideAgentHomes`).
        let fromShownTerminal = opensBrowser(action.id) && location.isOwnTab && caller.terminalID != nil
            && location.tab.kind == "terminal" && location.isShown(in: topology)
        if beside, placement.isBeside, !fromShownTerminal {
            return placeBeside(&request, action: action, placement: placement, topology: topology)
        }
        // An agent that stands in its session's workspace has no tab, pane or screen of its own to run anything else on.
        if !location.isOwnTab, !opens, kind != "workspace" { throw Self.callerNotLocated(caller, action: action) }
        switch kind {
        case "tab"?: request.target = ControlTargetRef(kind: "tab", id: location.tab.id)
        case "screen"?: request.target = ControlTargetRef(kind: "screen", id: location.screen.id)
        case "workspace"?: request.target = ControlTargetRef(kind: "workspace", id: location.workspace.id)
        default: request.target = ControlTargetRef(kind: "pane", id: location.pane.id)
        }
    }

    /// An agent's surface-opening run beside it. With a helper column a window shows, the app measures that
    /// column and places the tab as the chat header's Preview is placed (AgentBesidePlacement,
    /// RightColumnPlacement): a tab in the pane that already holds its kind, else a split below a lone pane,
    /// else a tab in the lowest pane; never a third column. Leo 2026-10-31: "imo in this case, just open it on
    /// the existing. you only need the rightmost botom auto split when there's a terminal that gets opened when
    /// there's already a browser, and vice versa". A column no window shows: the topology's column picks the
    /// pane. Without a helper column: the caller's own tab or pane, and the handler moves the new tab into a new
    /// column right of it.
    private static func placeBeside(_ request: inout ControlActionRequest, action: ControlActionInfo,
                                    placement: ControlCallerPlacement, topology: ControlTopology) {
        let location = placement.location
        let paneTarget = action.targets.contains("pane")
        let own = paneTarget ? ControlTargetRef(kind: "pane", id: location.pane.id) : ControlTargetRef(kind: "tab", id: location.tab.id)
        request.besideCaller = true
        // The diff viewer takes the column's pane as it is; a Chief turn's Home column is never measured.
        let measured = action.id != "openDiffViewer" && location.tab.page != "home-dock" && location.isShown(in: topology)
        let helper = action.id == "openDiffViewer" ? placement.column.first : placement.pane(for: besideKind(action.id))
        if placement.kind == .helperColumn, !measured, let helper,
           let target = paneTarget ? ControlTargetRef(kind: "pane", id: helper.id)
               : ControlCallerPlacement.anchorTab(of: helper).map({ ControlTargetRef(kind: "tab", id: $0) }) {
            request.target = target
        } else {
            // A new column, a column the app measures, or an empty one a tab target cannot name.
            request.target = own
            request.newColumnBeside = true
        }
        Self.fillCallerFolder(&request, action: action, location: location)
    }

    /// The folder the agent works in for a beside run that names none: the diff of the agent's folder, a new
    /// terminal there, never the folder of the pane the tab lands in.
    private static func fillCallerFolder(_ request: inout ControlActionRequest, action: ControlActionInfo, location: ControlCallerLocation) {
        guard let argument = ["openDiffViewer": "path", "newSurface": "cwd", "newTab.default": "cwd"][action.id], request.arguments[argument] == nil,
              action.arguments.contains(where: { $0.name == argument }), let cwd = location.tab.cwd, !cwd.isEmpty else { return }
        request.arguments[argument] = .string(cwd)
    }

    /// An agent named as the caller has no chat or terminal of its own in any workspace: its run has no tab or
    /// pane of its own.
    static func callerNotLocated(_ caller: ControlCaller, action: ControlActionInfo) -> ControlError {
        ControlError(code: "caller_unavailable",
                     message: ControlStrings.format("control.error.callerNotLocated",
                                                    "%@ has no target, and no tab shows the caller's chat or terminal; name the tab, pane or workspace to act on",
                                                    action.id),
                     data: ["action": .string(action.id), "agent_session": .optional(caller.agentSession),
                            "terminal_id": .optional(caller.terminalID)])
    }

    /// An agent's closing or destructive run names no target: it says which one, with its own ids to choose from.
    static func targetRequired(_ action: ControlActionInfo, location: ControlCallerLocation) -> ControlError {
        ControlError(code: "target_required",
                     message: ControlStrings.format("control.error.callerTargetRequired",
                                                    "%1$@ closes or removes what it runs on, so an agent must name the target; your own tab is %2$@",
                                                    action.id, location.tab.id),
                     data: ["action": .string(action.id), "tab": .string(location.tab.id), "pane": .string(location.pane.id),
                            "workspace": .string(location.workspace.publicID)])
    }
}
