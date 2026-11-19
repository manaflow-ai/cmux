import CmuxNextSettings
import Foundation

/// Who sent a control request (`caller`): the acpmux agent session the cmux
/// CLI or `cmux mcp serve` runs for (`CMUX_AGENT_SESSION`), else the caller's
/// own terminal (`CMUX_TUI_TERMINAL_ID`). The app finds an agent session's
/// chat tab by the topology's `agent_session` (ControlTopology+Tabs).
///
/// One placement rule (``ControlCallerPlacement``; beside_caller, hq-6d
/// right-column design): what a caller runs without naming a place stays in
/// its own workspace. A tab an agent opens goes to the column right of its
/// pane, on the same screen; with no such column the app makes one right of
/// it. Keyboard focus stays where it is. `snapshot.get` and `system.identify`
/// report the caller and that column (`caller`, `beside`), so an agent knows
/// where it is and where its tabs open.
struct ControlCaller: Sendable, Equatable {
    var agentSession: String?
    var terminalID: String?
    /// `caller.home_chat`: a Chief turn (the Chief host sets it). The app does
    /// not know a turn's agent session, so its chat is the Home chat.
    var homeChat = false
    /// `caller.workspace`: the key of the workspace the agent session runs in
    /// (`CMUX_WORKSPACE_ID`), where it is placed when no tab shows its chat.
    var workspaceKey: String?
    /// The request's `origin` is `mcp`: the cmux MCP server sent it, so an agent asks, also from a terminal
    /// whose hooks reported no agent (ControlCallerPlacement treats it as one).
    var viaMCP = false

    init(agentSession: String? = nil, terminalID: String? = nil, homeChat: Bool = false, workspaceKey: String? = nil,
         viaMCP: Bool = false) {
        self.agentSession = agentSession
        self.terminalID = terminalID
        self.homeChat = homeChat
        self.workspaceKey = workspaceKey
        self.viaMCP = viaMCP
    }

    /// The caller of a method that also takes the caller's terminal as its own param (`terminal_id`):
    /// `caller` when it is there, else that terminal.
    init?(_ params: [String: JSONValue], terminalID: String?) throws {
        if let caller = try ControlCaller(params) {
            self = caller
        } else if let terminalID {
            self = ControlCaller(terminalID: terminalID, viaMCP: params["origin"]?.stringValue == "mcp")
        } else {
            return nil
        }
    }

    /// The request's `caller`, nil when it names none. A malformed one is
    /// refused, never ignored.
    init?(_ params: [String: JSONValue]) throws {
        guard let raw = params["caller"], !raw.isNull else { return nil }
        guard case .object(let members) = raw else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.expectedJSONObject", "Expected JSON object"),
                                             data: ["param": "caller"])
        }
        func text(_ name: String) throws -> String? {
            guard let value = members[name], !value.isNull else { return nil }
            guard let text = value.stringValue else {
                throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", "caller." + name))
            }
            return text.isEmpty ? nil : text
        }
        agentSession = try text("agent_session")
        terminalID = try text("terminal_id")
        workspaceKey = try text("workspace")
        if let flag = members["home_chat"], !flag.isNull {
            guard case .bool(let on) = flag else {
                throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeBoolean", "%@ must be true or false", "caller.home_chat"))
            }
            homeChat = on
        }
        guard agentSession != nil || terminalID != nil || homeChat else {
            throw ControlError.invalidParams("caller must name agent_session, terminal_id, or home_chat")
        }
        viaMCP = params["origin"]?.stringValue == "mcp"
    }

    /// The `caller` param that names this caller again (a method that hands its run to `action.run`, with the
    /// request's `origin` beside it).
    var json: JSONValue {
        var members: [String: JSONValue] = [:]
        if let agentSession { members["agent_session"] = .string(agentSession) }
        if let terminalID { members["terminal_id"] = .string(terminalID) }
        if homeChat { members["home_chat"] = true }
        if let workspaceKey { members["workspace"] = .string(workspaceKey) }
        return .object(members)
    }
}

extension ControlActionRequest {
    /// The caller the request carries, nil when it named none.
    var caller: ControlCaller? {
        guard callerAgentSession != nil || callerTerminal != nil || callerHomeChat else { return nil }
        return ControlCaller(agentSession: callerAgentSession, terminalID: callerTerminal, homeChat: callerHomeChat,
                             workspaceKey: callerWorkspace, viaMCP: origin == "mcp")
    }
}

/// Where a caller is in the topology, and the column right of it.
struct ControlCallerLocation: Sendable, Equatable {
    var caller: ControlCaller
    var workspace: ControlWorkspaceInfo
    var screen: ControlScreenInfo
    var pane: ControlPaneInfo
    var tab: ControlTabInfo
    /// The pane of the column right of `pane` on its screen; nil when there
    /// is none (the app then makes one).
    var beside: ControlPaneInfo?
    /// Every pane of that column, in the screen's order (top to bottom); empty when there is none.
    var column: [ControlPaneInfo] = []
    /// Whether `tab` is the caller's own chat or terminal. False for a stand-in place: the Home chat of
    /// a Chief turn, or a pane of the workspace an agent's session runs in when no tab shows its chat.
    /// What the caller opens is placed from a stand-in; a run on "its own" tab or pane has none there.
    var isOwnTab = true

    /// Where the caller is: its chat tab (agent session) or terminal tab; else, for a Chief turn,
    /// the Home chat; else, for an agent whose chat no tab shows (its tab was closed, or a Chief
    /// subagent told again later), the workspace its session runs in (``ownWorkspace(_:in:)``).
    /// Nil when none of these is in the topology: the caller is refused, never placed in the
    /// focused workspace, which is Home while the person talks to the Chief (user, 2026-11-18).
    static func resolve(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        if let own = own(caller, in: topology) { return own }
        return caller.homeChat ? homeChat(caller, in: topology) : ownWorkspace(caller, in: topology)
    }

    /// An agent's own workspace by the key its session runs in (`caller.workspace`), at the pane a
    /// window shows focused there, else a screen's default pane, else its first pane with a tab.
    static func ownWorkspace(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        guard caller.agentSession != nil, let key = caller.workspaceKey.map(workspaceKeyForm), !key.isEmpty,
              let workspace = topology.workspaces.first(where: { workspaceKeyForm($0.id) == key }) else { return nil }
        var candidates: [(screen: ControlScreenInfo, pane: ControlPaneInfo)] = []
        for window in topology.windows where window.workspaceID == workspace.id {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.id == window.focusedPaneID }) { candidates.append((screen, pane)) }
            }
        }
        for screen in workspace.screens {
            if let pane = screen.panes.first(where: { $0.id == screen.defaultPaneID }) { candidates.append((screen, pane)) }
            candidates += screen.panes.map { (screen, $0) }
        }
        for (screen, pane) in candidates {
            guard let tab = pane.tabs.first(where: { $0.id == pane.selectedTabID }) ?? pane.tabs.first else { continue }
            return Self(caller: caller, workspace: workspace, screen: screen, pane: pane, tab: tab,
                        beside: besidePane(of: pane, on: screen), column: besideColumn(of: pane, on: screen), isOwnTab: false)
        }
        return nil
    }

    /// The Home workspace's docked chat tab (page `home-dock`, HomeDock.page),
    /// for a Chief turn whose own session the topology does not show.
    static func homeChat(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        for workspace in topology.workspaces where workspace.kind == "home" {
            for screen in workspace.screens {
                for pane in screen.panes {
                    guard let tab = pane.tabs.first(where: { $0.page == "home-dock" }) else { continue }
                    return Self(caller: caller, workspace: workspace, screen: screen, pane: pane, tab: tab,
                                beside: besidePane(of: pane, on: screen), column: besideColumn(of: pane, on: screen), isOwnTab: false)
                }
            }
        }
        return nil
    }

    private static func own(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        for workspace in topology.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    let tab = pane.tabs.first { tab in
                        if let session = caller.agentSession { return tab.agentSessionID == session }
                        guard let terminal = caller.terminalID else { return false }
                        return tab.terminalID == terminal || tab.terminalResourceID == terminal
                    }
                    guard let tab else { continue }
                    return Self(caller: caller, workspace: workspace, screen: screen, pane: pane, tab: tab,
                                beside: besidePane(of: pane, on: screen), column: besideColumn(of: pane, on: screen))
                }
            }
        }
        return nil
    }

    /// The first pane directly right of `pane` (``besideColumn(of:on:)``).
    static func besidePane(of pane: ControlPaneInfo, on screen: ControlScreenInfo) -> ControlPaneInfo? {
        besideColumn(of: pane, on: screen).first
    }

    /// The panes directly right of `pane`, top to bottom: what the daemon's layout says (`rightPaneIDs`: the
    /// panes across a side-by-side split of its own column, else the next scrolling column's), the same on and
    /// off screen. Only a scrolling column counts: a dock (another chat dock, a tool dock) never takes an agent's
    /// tabs, so a chat in the strip's last column gets a new column instead. A topology with no layout (built by
    /// hand) has the next column's panes (`column + 1`), in the screen's order.
    static func besideColumn(of pane: ControlPaneInfo, on screen: ControlScreenInfo) -> [ControlPaneInfo] {
        if let right = pane.rightPaneIDs {
            return right.compactMap { id in screen.panes.first { $0.id == id && $0.dock == nil } }
        }
        guard let column = pane.column else { return [] }
        return screen.panes.filter { $0.column == column + 1 && $0.dock == nil }
    }

    /// The kinds of tab `pane` holds, for the same-kind rule (RightColumnPlacement): `terminal`, and
    /// `browser` for a web page (never an app page tab such as the diff viewer).
    static func kinds(of pane: ControlPaneInfo) -> Set<String> {
        var kinds: Set<String> = []
        for tab in pane.tabs {
            if tab.kind == "terminal" { kinds.insert("terminal") }
            if tab.kind == "browser", tab.page == nil { kinds.insert("browser") }
        }
        return kinds
    }

    /// Whether a window shows the caller's workspace, so the app can measure the column on screen.
    func isShown(in topology: ControlTopology) -> Bool {
        topology.windows.contains { $0.isVisible && !$0.isHidden && $0.workspaceID == workspace.id }
    }

    var callerJSON: JSONValue {
        ["is_caller": true, "agent_session": .optional(caller.agentSession), "terminal_id": .optional(caller.terminalID),
         "workspace": .string(workspace.publicID), "screen": .string(screen.id), "pane": .string(pane.id), "tab": .string(tab.id),
         "column": pane.column.map { JSONValue($0) } ?? .null]
    }

    /// `members` with `caller`, `beside` and `browser` (the browser nearest
    /// it, ``BrowserCallerTarget``) for `params`' caller, when the topology
    /// shows it (`snapshot.get`, `system.identify`).
    static func annotate(_ members: inout [String: JSONValue], params: [String: JSONValue], topology: ControlTopology) throws {
        guard let caller = try ControlCaller(params) else { return }
        guard let location = resolve(caller, in: topology) else {
            members["caller"] = ["is_caller": true, "agent_session": .optional(caller.agentSession),
                                 "terminal_id": .optional(caller.terminalID), "found": false]
            return
        }
        members["caller"] = location.callerJSON
        // Where its tabs open: the decision the app makes for its runs (the CLI and the MCP server place terminals from it).
        members["beside"] = ControlCallerPlacement(location).besideJSON
        // The browser its `current` browser commands drive (#26648), in its own session: the
        // daemon the CLI and MCP address.
        members["browser"] = BrowserCallerTarget.resolve(near: location, in: topology)?.json ?? .null
    }
}

/// A workspace key in one form: `CMUX_WORKSPACE_ID` is upper-case and dashed, the topology's key lower-case.
func workspaceKeyForm(_ key: String) -> String {
    key.lowercased().filter { $0 != "-" }
}
