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
/// - An agent's run that closes or destroys is refused until it names its object, by a target or by the
///   action's own argument (``requireObjectOfAgentClosing``, ControlRouter+CallerActionClass.swift, before
///   anything is aimed): for an agent, "this tab" may be its own home, the tab it opened last, or the nearest
///   browser, and the wrong guess ends the agent or loses the person's work. A closing run is never aimed at an
///   agent's own place, and one named by its argument is not aimed at all. A person's shell keeps its own tab,
///   pane, screen or workspace, which is what its focused run meant.
/// - A browser from a terminal, an agent's or a person's shell, opens right of the terminal: aimed at the
///   terminal's own tab while a window shows it (the app measures, as a Cmd-click's), placed from the topology
///   as an agent's is while none does. A run aimed at the caller's own terminal tab is that same request.
/// - An agent whose chat no tab shows stands in the workspace its session runs in (`caller.workspace`): what it
///   opens is placed from there and a workspace run is that workspace; it has no tab or pane of its own, so any
///   other run is refused. An agent cmux cannot place at all is refused (`caller_unavailable`), never run on the
///   focused pane, which is Home while the person talks to the Chief (user, 2026-11-18); only
///   ``workspaceCreatingActions`` still run.
/// - A Chief turn (`caller.home_chat`) acts for the person across the app: only what it opens beside itself is
///   placed, beside the Home chat; its other runs are unchanged.
/// - An action on a tab group, a screen group or a workspace group runs on the group of the caller's own tab,
///   screen or workspace (``callerPlaceKind(of:)``).
/// - An action on the person's front window, Space or bookmark is never aimed: an agent must name its object
///   (``CallerActionClass/personsFront``).
/// - An action with no such target kind (settings, the palette) and a run with a target or no caller are unchanged.
///
/// Existing-browser actions are aimed first, at the browser nearest the caller (``aimBrowserActionAtCaller``).
extension ControlRouter {
    /// The actions, with the browser (``opensBrowserTab(_:)``), whose handlers place the new tab beside an agent
    /// caller (AgentBesidePlacement): selected in its helper column, or moved into a new column right of it.
    static let besideCallerActions: Set<String> = [
        "openDiffViewer", "file.open", "openMarkdownFile", "newSurface", "newTab.default", "newTab.ofKind",
    ]

    /// `openBrowser` and its engine variants (`openBrowser.webkit`, `openBrowser.chromium`).
    static func opensBrowser(_ id: String) -> Bool { id == "openBrowser" || id.hasPrefix("openBrowser.") }

    /// A new tab or a link in a browser profile, and a history entry (its page): for a caller their handlers open
    /// the page through `openBrowser`'s path, never in the tab the person has focused.
    static let profileBrowserActions: Set<String> = ["browserProfile.newTab", "browserProfile.openLink", "history.open"]

    /// Whether `id` opens a browser tab: ``opensBrowser(_:)`` and ``profileBrowserActions``.
    static func opensBrowserTab(_ id: String) -> Bool { opensBrowser(id) || profileBrowserActions.contains(id) }

    /// Whether `id` opens a tab that goes beside an agent caller.
    static func opensBeside(_ id: String) -> Bool { opensBrowserTab(id) || besideCallerActions.contains(id) }

    /// The kind the same-kind rule reads for what `id` opens (`browser`, `terminal`); nil: no kind.
    static func besideKind(_ id: String) -> String? { opensBrowserTab(id) ? "browser" : id == "newSurface" ? "terminal" : nil }

    /// The other actions that open a new tab or page where their target is: run by an agent with
    /// no target they open in the agent's own place, never in the focused pane. A new workspace or
    /// window (`newTab`, `newWindow`) is not one: it opens no tab in an existing workspace.
    static func opensSurface(_ id: String) -> Bool {
        ["new.", "newSurface", "tabGroup.newTab", "file.open", "macScreen.open", "reopenClosedBrowserPanel"].contains { id.hasPrefix($0) }
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
        if let target = request.target {
            // An explicit target wins, but for one: a terminal's browser aimed at that terminal's own tab is how
            // the CLI's `browser open` says "from this terminal". It is placed as that terminal's browser.
            guard opensBrowser(action.id), caller.terminalID != nil, normalizedKind(target.kind) == "tab",
                  let location = ControlCallerLocation.resolve(caller, in: topology), location.isOwnTab,
                  (try? PublicIDTargetResolver.resolve(target, in: topology))?.id == location.tab.id else { return }
            request.target = nil
        }
        // Open in the editor app opens nothing in cmux: there is no place to choose.
        if action.id == "file.open", request.arguments["where"] == .string("editor") { return }
        // A closing run that names its object by argument (`--session`, `--window`) acts on that, and one on a
        // window has no place of the caller's: neither is aimed at the caller's own tab or workspace.
        let actionClass = callerClass(of: action)
        if actionClass == .personsFront || (actionClass == .closing && namesObject(request, action: action)) { return }
        let beside = opensBeside(action.id), opens = beside || opensSurface(action.id)
        // A group action is aimed at the caller's own tab, screen or workspace: its handler reads that one's group.
        let kind = callerPlaceKind(of: action)
        guard beside || (kind != nil && !caller.homeChat) else { return }
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            guard caller.agentSession != nil || caller.homeChat else { return }
            if opens { throw BrowserCallerTarget.missingCaller(caller) }
            // Before the first topology (the app starts) nothing can be located: the handler decides, as before.
            guard topology.isLoaded, !workspaceCreatingActions.contains(action.id) else { return }
            throw Self.callerNotLocated(caller, action: action)
        }
        // A browser from a terminal, an agent's or a person's, opens right of the terminal (Lawrence 2026-11-15).
        let terminalBrowser = opensBrowserTab(action.id) && location.isOwnTab && caller.terminalID != nil && location.tab.kind == "terminal"
        let placement = ControlCallerPlacement(location, browserFromTerminal: terminalBrowser)
        request.besideAgentHomes = placement.agentHomes
        if terminalBrowser, location.isShown(in: topology) {
            // A window shows the terminal: the app measures as a Cmd-click's from it (TabLifecycle): the pane on
            // its right, else a new pane beside it, never one of another agent (`besideAgentHomes`). The run is
            // aimed at the terminal's own tab, which is how that rule knows its caller.
            request.target = ControlTargetRef(kind: "tab", id: location.tab.id)
            return
        }
        // No window shows it (the person looks at another workspace): the topology decides, as for an agent's chat.
        if beside, placement.isBeside {
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
}
