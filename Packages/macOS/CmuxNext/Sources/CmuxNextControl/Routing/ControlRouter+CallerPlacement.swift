import CmuxNextSettings
import Foundation

/// `action.run` for a run that names a caller and no target (``ControlCallerPlacement``): the run uses the
/// caller's own place, never the app's focus.
///
/// - A surface-opening action whose handler places its new tab (``besideCallerActions``) goes beside the caller: in
///   its helper column, else in a new column right of its pane; a terminal no agent runs in keeps it in its own pane.
/// - Any other action that takes a tab, pane or workspace target runs on the caller's own tab, pane or workspace
///   (a rename renames its own workspace). That includes the opens that name their own place (Split Right, New
///   Column, New Terminal to the Right, New Tab at End): they split or fill the caller's own pane, as asked.
/// - An agent's run that closes or destroys (``closingActions``, the catalog's destructive actions) is refused
///   until it names its target: for an agent, "this tab" may be its own home or the tab it opened last, and the
///   wrong guess ends the agent or loses the person's work. A person's shell keeps its own tab, pane or workspace,
///   which is what its focused run meant.
/// - An agent the topology does not show has no place: its opens and its runs on a tab, pane or workspace are
///   refused (`caller_unavailable`), never run on the focused one; only ``workspaceCreatingActions`` still run.
/// - An action with no such target kind (settings, the palette) and a run with a target or no caller are unchanged.
///
/// Existing-browser actions are aimed first, at the browser nearest the caller (``aimBrowserActionAtCaller``).
extension ControlRouter {
    /// The surface-opening actions whose handlers place the new tab beside the caller (AgentBesidePlacement),
    /// with the kind the same-kind rule reads (`browser`, `terminal`; nil: no kind).
    static let besideCallerActions: [String: String?] = [
        "openBrowser": "browser", "openBrowser.webkit": "browser", "openBrowser.chromium": "browser",
        "openDiffViewer": nil, "file.open": nil, "openMarkdownFile": nil,
        "newSurface": "terminal", "newTab.default": nil, "newTab.ofKind": nil,
    ]

    /// The target kinds a caller has of its own, in no order: an action lists its own first.
    static let callerTargetKinds: Set<String> = ["tab", "pane", "workspace"]

    /// Actions that close or put away what they act on and that the catalog does not mark destructive.
    static let closingActions: Set<String> = [
        "closeTab", "closeOtherTabsInPane", "closeTabsToLeft", "closeTabsToRight", "closePane", "pane.closeOthers",
        "workspace.toggleArchive", "workspace.archiveOtherWorkspaces", "workspace.archiveOthersInGroup",
        "workspace.archiveWorkspacesBelow", "workspace.archiveWorkspacesAbove", "agentPane.archiveChat",
    ]

    /// Actions that make a workspace and take a workspace target only as the place of its sidebar row: an agent
    /// with no chat or terminal of its own (a session no tab shows) still runs them.
    static let workspaceCreatingActions: Set<String> = [
        "newTab", "newBrowserWorkspace", "openFolder", "palette.openFolderInVSCodeInline", "palette.layout.open",
        "workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom", "workspace.newInNewGroup",
        "workspace.newOnMachine", "newWorkspaceGroup", "reopenClosedWorkspace", "reopenPreviousSession",
    ]

    /// Aims a run that names a caller and no target at the caller's own place. A caller the topology does not
    /// show is refused for an agent (it has no place, and the focused pane is never its place); a terminal the
    /// topology does not show is another session's, and its run is left as it is.
    static func placeAtCaller(_ request: inout ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        guard request.target == nil, let caller = request.caller else { return }
        let opens = besideCallerActions[action.id] != nil
        let kind = action.targets.first { callerTargetKinds.contains($0) }
        guard opens || kind != nil else { return }
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            guard caller.agentSession != nil || caller.homeChat else { return }
            if opens { throw BrowserCallerTarget.missingCaller(caller) }
            // Before the first topology (the app starts) nothing can be located: the handler decides, as before.
            guard topology.isLoaded, !workspaceCreatingActions.contains(action.id) else { return }
            throw Self.callerNotLocated(caller, action: action)
        }
        let placement = ControlCallerPlacement(location)
        if opens, placement.isBeside {
            return placeBeside(&request, action: action, placement: placement, topology: topology)
        }
        if placement.isBeside, action.isDestructive || closingActions.contains(action.id) {
            throw Self.targetRequired(action, location: location)
        }
        switch kind {
        case "tab"?: request.target = ControlTargetRef(kind: "tab", id: location.tab.id)
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
        request.besideAgentHomes = placement.agentHomes
        // The diff viewer takes the column's pane as it is; a Chief turn's Home column is never measured.
        let measured = action.id != "openDiffViewer" && location.tab.page != "home-dock" && location.isShown(in: topology)
        let kind = besideCallerActions[action.id] ?? nil
        let helper = action.id == "openDiffViewer" ? placement.column.first : placement.pane(for: kind)
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

    /// An agent named as the caller has no chat or terminal in any workspace: its run has no place of its own.
    static func callerNotLocated(_ caller: ControlCaller, action: ControlActionInfo) -> ControlError {
        ControlError(code: "caller_unavailable",
                     message: ControlStrings.format("control.error.callerNotLocated",
                                                    "%@ has no target, and the caller's chat or terminal is in no workspace; name the tab, pane or workspace to act on",
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
