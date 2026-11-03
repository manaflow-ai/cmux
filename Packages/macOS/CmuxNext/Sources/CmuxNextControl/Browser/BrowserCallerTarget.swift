import CmuxNextSettings
import Foundation

/// The browser an agent drives when it names none (#26648): the one nearest
/// its caller (`caller`, ControlCaller), never the person's focused tab in
/// another window. Nearest is, in order: a browser in the caller's own
/// workspace, then one in a workspace of its sidebar group, then one in
/// another workspace of its window, each nearest in the sidebar first. In a
/// workspace, the person's focused tab wins when it is a browser there, then
/// a browser a pane shows (the column right of the caller's chat first, then
/// by column distance), then any browser tab, the newest in its pane.
///
/// `browser.page.*` without `tab` runs on this tab, `system.identify` and
/// `snapshot.get` report it (`browser`), and the cmux CLI and MCP server put
/// it in place of a `current` browser selector. A call without a caller keeps
/// the focused tab. A supplied caller that the topology no longer shows is refused.
struct BrowserCallerTarget: Sendable, Equatable {
    var workspace: ControlWorkspaceInfo
    var screen: ControlScreenInfo
    var pane: ControlPaneInfo
    var tab: ControlTabInfo
    /// The pane that shows the tab now: its own pane when it is that pane's selected tab, the
    /// mirroring pane for a mirrored tab it shows; nil when no pane shows it.
    var shownIn: ControlPaneInfo?

    /// A focused mirror refers to its owning tab, while the focus path names its showing pane.
    func isFocused(in topology: ControlTopology) -> Bool {
        guard topology.focus.tabID == tab.id, let shownIn, topology.focus.paneID == shownIn.id else { return false }
        return topology.workspaces.contains { workspace in
            workspace.id == topology.focus.workspaceID && workspace.sessionID == self.workspace.sessionID
                && workspace.panes.contains { $0.id == shownIn.id }
        }
    }

    /// The browser nearest `location`, nil when none is in its workspace, group or window. It keeps
    /// to the caller's own session (the daemon the CLI and MCP address), so page verbs, actions and
    /// `identify` always pick the same browser.
    static func resolve(near location: ControlCallerLocation, in topology: ControlTopology) -> Self? {
        for workspace in nearbyWorkspaces(of: location.workspace, in: topology)
        where workspace.sessionID == location.workspace.sessionID {
            if let found = browser(in: workspace, near: workspace.id == location.workspace.id ? location : nil, topology: topology) {
                return found
            }
        }
        return nil
    }

    /// The caller's exact live location, or nil when no caller was provided.
    /// An explicitly supplied stale or empty caller must never select the person's focused tab.
    static func callerLocation(params: [String: JSONValue], in topology: ControlTopology) throws -> ControlCallerLocation? {
        guard let caller = try ControlCaller(params) else {
            if let provided = params["caller"], !provided.isNull {
                throw ControlError.invalidParams("caller must name agent_session, terminal_id, or home_chat")
            }
            return nil
        }
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            throw missingCaller(caller)
        }
        return location
    }

    /// The browser nearest the exact caller, or nil only when the request names no caller.
    static func resolve(params: [String: JSONValue], in topology: ControlTopology) throws -> Self? {
        guard let location = try callerLocation(params: params, in: topology) else { return nil }
        guard let found = resolve(near: location, in: topology) else { throw notFound(near: location) }
        return found
    }

    /// A lost caller cannot transfer its authorization or page intent to the focused tab.
    static func missingCaller(_ caller: ControlCaller) -> ControlError {
        ControlError(code: "caller_unavailable",
                     message: "The caller's chat or terminal is no longer available; name an existing browser tab",
                     data: ["agent_session": .optional(caller.agentSession), "terminal_id": .optional(caller.terminalID)])
    }

    static func notFound(near location: ControlCallerLocation) -> ControlError {
        ControlError(code: "not_found",
                     message: ControlStrings.format("control.error.noBrowserNearCaller",
                                                    "No browser in workspace %@ or its window; list every tab with `cmux browser page tabs --all` and name one (`cmux browser tab_… <verb>`)",
                                                    location.workspace.publicID),
                     data: ["workspace": .string(location.workspace.publicID)])
    }

    /// `browser` for `system.identify` and `snapshot.get`: where the caller's browser is.
    var json: JSONValue {
        ["tab": .string(tab.id), "pane": .string(pane.id), "screen": .string(screen.id), "workspace": .string(workspace.publicID),
         "session": .optional(workspace.sessionID), "url": .optional(tab.url)]
    }

    /// `own` first, then the workspaces of its sidebar group, then the rest of its window, each by
    /// sidebar distance from `own` (above before below on a tie). A group outside any window keeps
    /// to its own members; no other window's workspace is ever near.
    static func nearbyWorkspaces(of own: ControlWorkspaceInfo, in topology: ControlTopology) -> [ControlWorkspaceInfo] {
        let order = topology.windows.first { $0.workspaceIDs.contains(own.id) }?.workspaceIDs
        let others = topology.workspaces.filter { $0.id != own.id }
        guard let order, let at = order.firstIndex(of: own.id) else {
            return [own] + (own.groupID.map { group in others.filter { $0.groupID == group } } ?? [])
        }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let windowed = others.compactMap { workspace in position[workspace.id].map { (workspace, $0) } }
        func nearest(_ rows: [(ControlWorkspaceInfo, Int)]) -> [ControlWorkspaceInfo] {
            rows.sorted { (abs($0.1 - at), $0.1) < (abs($1.1 - at), $1.1) }.map(\.0)
        }
        let sameGroup = { (workspace: ControlWorkspaceInfo) in own.groupID != nil && workspace.groupID == own.groupID }
        return [own] + nearest(windowed.filter { sameGroup($0.0) }) + nearest(windowed.filter { !sameGroup($0.0) })
    }

    /// The browser of `workspace` to drive; `location` orders its panes from the caller's chat.
    static func browser(in workspace: ControlWorkspaceInfo, near location: ControlCallerLocation?, topology: ControlTopology) -> Self? {
        let panes = orderedPanes(of: workspace, near: location)
        func found(_ tab: ControlTabInfo, _ screen: ControlScreenInfo, _ pane: ControlPaneInfo) -> Self {
            Self(workspace: workspace, screen: screen, pane: pane, tab: tab, shownIn: pane.selectedTabID == tab.id ? pane : nil)
        }
        if topology.focus.workspaceID == workspace.id, let focused = topology.focus.tabID {
            for (screen, pane) in panes {
                if let tab = pane.tabs.first(where: { $0.id == focused }), isBrowser(tab) { return found(tab, screen, pane) }
            }
        }
        // A browser a pane shows: its own selected tab, or a mirrored one it lists.
        for (screen, pane) in panes {
            guard let selected = pane.selectedTabID else { continue }
            if let tab = pane.tabs.first(where: { $0.id == selected }), isBrowser(tab) { return found(tab, screen, pane) }
            // A mirrored tab is reported where it lives, so its path names its own pane.
            if pane.mirroredTabIDs.contains(selected),
               var shown = locate(selected, sessionID: workspace.sessionID, in: topology), isBrowser(shown.tab) {
                shown.shownIn = pane
                return shown
            }
        }
        for (screen, pane) in panes {
            if let tab = pane.tabs.last(where: isBrowser) { return found(tab, screen, pane) }
        }
        return nil
    }

    /// The unique tab `id` in the caller's session, with its owning workspace, screen and pane.
    private static func locate(_ id: String, sessionID: String?, in topology: ControlTopology) -> Self? {
        var found: Self?
        for workspace in topology.workspaces where workspace.sessionID == sessionID {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.id == id {
                        guard found == nil else { return nil }
                        found = Self(workspace: workspace, screen: screen, pane: pane, tab: tab, shownIn: pane.selectedTabID == id ? pane : nil)
                    }
                }
            }
        }
        return found
    }

    /// A browser tab the app shows a web page in (an internal page such as the Home chat is not one).
    static func isBrowser(_ tab: ControlTabInfo) -> Bool { tab.kind == "browser" && tab.page == nil }

    /// `workspace`'s panes: with `location`, the caller's screen first, the column right of its
    /// chat first there, then by column distance from the chat; otherwise in screen order.
    private static func orderedPanes(of workspace: ControlWorkspaceInfo, near location: ControlCallerLocation?)
        -> [(ControlScreenInfo, ControlPaneInfo)] {
        let panes = workspace.screens.flatMap { screen in screen.panes.map { (screen, $0) } }
        guard let location else { return panes }
        func rank(_ screen: ControlScreenInfo, _ pane: ControlPaneInfo) -> (Int, Int, Int) {
            let distance = if let column = pane.column, let own = location.pane.column { abs(column - own) } else { Int.max }
            return (screen.id == location.screen.id ? 0 : 1, pane.id == location.beside?.id ? 0 : 1, distance)
        }
        return panes.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element.0, lhs.element.1), rank(rhs.element.0, rhs.element.1))
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

extension ControlRouter {
    /// Aims an existing-browser action (`browser back`, `browser edit-source`) that an
    /// agent or a cmux terminal runs without a target at the
    /// browser nearest its caller (#26648), so it never acts on the person's focused browser in
    /// another window. A pane-target action gets the pane that shows that browser (the mirroring
    /// pane for a mirrored tab), a tab-target action the tab. A browser no pane shows, or one an
    /// untargeted action cannot name while the person's focus is elsewhere, is refused with the
    /// page verb that reaches it; so is a caller with no browser near it. A run with a target or
    /// no caller is left as it is.
    static func aimBrowserActionAtCaller(_ request: inout ControlActionRequest, action: ControlActionInfo,
                                         topology: ControlTopology) throws {
        let browserAction = action.requires.contains("browserFocused")
            || (action.category == "browser" && action.requires.contains("webViewFocused"))
            // Inspectors and Edit Source have no focus requirement, but still act on an existing browser.
            || ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement", "browser.editSource"].contains(action.id)
        guard request.target == nil, browserAction,
              request.callerAgentSession != nil || request.callerTerminal != nil || request.callerHomeChat else { return }
        let caller = ControlCaller(agentSession: request.callerAgentSession, terminalID: request.callerTerminal,
                                   homeChat: request.callerHomeChat)
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            throw BrowserCallerTarget.missingCaller(caller)
        }
        guard let near = BrowserCallerTarget.resolve(near: location, in: topology) else {
            throw BrowserCallerTarget.notFound(near: location)
        }
        if action.targets.contains("pane"), let shown = near.shownIn {
            request.target = ControlTargetRef(kind: "pane", id: shown.id)
        } else if action.targets.contains("tab") {
            request.target = ControlTargetRef(kind: "tab", id: near.tab.id)
        } else if action.targets.contains("pane") || !near.isFocused(in: topology) {
            throw ControlError(code: "unavailable",
                               message: ControlStrings.format("control.error.callerBrowserNotShown",
                                                              "%1$@ cannot reach your browser %2$@: no pane shows it, or it is not the focused tab; use a page verb on it: `cmux browser %2$@ <verb>`",
                                                              action.id, near.tab.id),
                               data: ["action": .string(action.id), "tab": .string(near.tab.id)])
        }
    }
}
