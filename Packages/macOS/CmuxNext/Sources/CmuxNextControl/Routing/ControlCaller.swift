import CmuxNextSettings
import Foundation

/// Who sent a control request (`caller`): the acpmux agent session the cmux
/// CLI or `cmux mcp serve` runs for (`CMUX_AGENT_SESSION`), else the caller's
/// own terminal (`CMUX_TUI_TERMINAL_ID`). The app finds an agent session's
/// chat tab by the topology's `agent_session` (ControlTopology+Tabs).
///
/// One placement rule (beside_caller, hq-6d right-column design): a tab an
/// agent opens without naming a pane or workspace goes to the column right
/// of its chat's pane, on the same screen; with no such column the app makes
/// one right of the chat. Keyboard focus stays in the chat. `snapshot.get`
/// and `system.identify` report the caller and that column (`caller`,
/// `beside`), so an agent knows where it is and where its tabs open.
struct ControlCaller: Sendable, Equatable {
    var agentSession: String?
    var terminalID: String?
    /// `caller.home_chat`: a Chief turn (the Chief host sets it). The app does
    /// not know a turn's agent session, so its chat is the Home chat.
    var homeChat = false

    init(agentSession: String? = nil, terminalID: String? = nil, homeChat: Bool = false) {
        self.agentSession = agentSession
        self.terminalID = terminalID
        self.homeChat = homeChat
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
        if let flag = members["home_chat"], !flag.isNull {
            guard case .bool(let on) = flag else {
                throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeBoolean", "%@ must be true or false", "caller.home_chat"))
            }
            homeChat = on
        }
        guard agentSession != nil || terminalID != nil || homeChat else {
            throw ControlError.invalidParams("caller must name agent_session, terminal_id, or home_chat")
        }
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

    /// The caller's chat tab (agent session) or terminal tab, nil when the
    /// topology shows neither.
    static func resolve(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        own(caller, in: topology) ?? (caller.homeChat ? homeChat(caller, in: topology) : nil)
    }

    /// The Home workspace's docked chat tab (page `home-dock`, HomeDock.page),
    /// for a Chief turn whose own session the topology does not show.
    static func homeChat(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
        for workspace in topology.workspaces where workspace.kind == "home" {
            for screen in workspace.screens {
                for pane in screen.panes {
                    guard let tab = pane.tabs.first(where: { $0.page == "home-dock" }) else { continue }
                    return Self(caller: caller, workspace: workspace, screen: screen, pane: pane, tab: tab,
                                beside: besidePane(of: pane, on: screen), column: besideColumn(of: pane, on: screen))
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

    /// The first pane of the next column right of `pane` (`column`, as the
    /// window draws columns left to right). Only a scrolling column counts:
    /// a dock (another chat dock, a tool dock) never takes an agent's tabs,
    /// so a chat in the strip's last column gets a new column instead.
    static func besidePane(of pane: ControlPaneInfo, on screen: ControlScreenInfo) -> ControlPaneInfo? {
        guard let column = pane.column else { return nil }
        return screen.panes.first { $0.column == column + 1 && $0.dock == nil }
    }

    /// Every pane of that column (``besidePane(of:on:)``'s), in the screen's order.
    static func besideColumn(of pane: ControlPaneInfo, on screen: ControlScreenInfo) -> [ControlPaneInfo] {
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

    /// A tab of the beside pane to aim an `openBrowser` at: its selected tab, else its first.
    var besideTab: String? {
        guard let beside else { return nil }
        if let selected = beside.selectedTabID, beside.tabs.contains(where: { $0.id == selected }) { return selected }
        return beside.tabs.first?.id
    }

    var callerJSON: JSONValue {
        ["is_caller": true, "agent_session": .optional(caller.agentSession), "terminal_id": .optional(caller.terminalID),
         "workspace": .string(workspace.publicID), "screen": .string(screen.id), "pane": .string(pane.id), "tab": .string(tab.id),
         "column": pane.column.map { JSONValue($0) } ?? .null]
    }

    /// `beside`: the column the caller's new tabs open in, or `null` pane with
    /// `new_column` when the app would make one.
    var besideJSON: JSONValue {
        guard let beside else { return ["pane": .null, "placement": "new_column"] }
        // `panes`: the whole column, top to bottom, with the kinds each holds, so a terminal the CLI
        // or MCP server opens goes to the pane that already holds a terminal, or splits below a lone
        // pane of another kind (cmux-tui cli/beside.rs).
        let panes: [JSONValue] = (column.isEmpty ? [beside] : column).map { pane in
            ["id": .string(pane.id), "kinds": .array(Self.kinds(of: pane).sorted().map(JSONValue.string))]
        }
        return ["pane": .string(beside.id), "column": beside.column.map { JSONValue($0) } ?? .null, "placement": "existing_column",
                "panes": .array(panes),
                "selected_tab": .optional(beside.selectedTabID),
                "tabs": .array(beside.tabs.map { tab in
                    ["id": .string(tab.id), "kind": .string(tab.page == nil ? tab.kind : "page"), "title": .string(tab.title),
                     "url": .optional(tab.url)]
                })]
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
        members["beside"] = location.besideJSON
        // The browser its `current` browser commands drive (#26648), in its own session: the
        // daemon the CLI and MCP address.
        members["browser"] = BrowserCallerTarget.resolve(near: location, in: topology)?.json ?? .null
    }
}

extension ControlRouter {
    /// The actions `beside_caller` places (phase 1: the browser and the diff viewer).
    static let besideCallerActions: Set<String> = ["openBrowser", "openDiffViewer"]

    /// Aims an agent's surface-opening run that names no target at the
    /// column right of its chat (beside_caller). An explicit target wins;
    /// a caller the topology does not show is refused.
    static func placeBesideCaller(_ request: inout ControlActionRequest, action: ControlActionInfo, topology: ControlTopology) throws {
        guard besideCallerActions.contains(action.id), request.target == nil,
              request.callerAgentSession != nil || request.callerHomeChat else { return }
        let caller = ControlCaller(agentSession: request.callerAgentSession, homeChat: request.callerHomeChat)
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            throw BrowserCallerTarget.missingCaller(caller)
        }
        let paneTarget = action.targets.contains("pane")
        // An agent's browser beside a column that is already there: the app measures that column and
        // places it as the chat header's Preview is placed (AgentBesidePlacement, RightColumnPlacement):
        // a tab in the pane that already holds a browser, else a split below a lone pane, else a tab
        // in the lowest pane; never a third column. Leo 2026-10-31: "imo in this case, just open it
        // on the existing. you only need the rightmost botom auto split when there's a terminal that
        // gets opened when there's already a browser, and vice versa".
        if action.id == "openBrowser", !paneTarget, location.beside != nil, request.callerAgentSession != nil,
           !location.caller.homeChat, location.isShown(in: topology) {
            request.target = ControlTargetRef(kind: "tab", id: location.tab.id)
            request.newColumnBeside = true
            request.besideCaller = true
            return
        }
        // A workspace no window shows: no measure, so the topology's column picks the pane.
        if action.id == "openBrowser", !paneTarget, let pane = sameKindOrLowest(location, kind: "browser"),
           let tab = pane.selectedTabID.flatMap({ id in pane.tabs.contains { $0.id == id } ? id : nil }) ?? pane.tabs.first?.id {
            request.target = ControlTargetRef(kind: "tab", id: tab)
            request.besideCaller = true
            return
        }
        if let beside = location.beside, paneTarget {
            request.target = ControlTargetRef(kind: "pane", id: beside.id)
        } else if location.beside != nil, let tab = location.besideTab {
            request.target = ControlTargetRef(kind: "tab", id: tab)
        } else {
            // No column right of the chat (or an empty one a tab target cannot name): a new column.
            request.target = paneTarget ? ControlTargetRef(kind: "pane", id: location.pane.id)
                : ControlTargetRef(kind: "tab", id: location.tab.id)
            request.newColumnBeside = true
        }
        request.besideCaller = true
        // The diff of the folder the agent works in, not the beside pane's.
        if action.id == "openDiffViewer", request.arguments["path"] == nil, let cwd = location.tab.cwd, !cwd.isEmpty {
            request.arguments["path"] = .string(cwd)
        }
    }

    /// With no window to measure: the column's lowest pane holding `kind`, else its lowest pane when it
    /// has two or more (RightColumnPlacement: never another split); nil leaves the column's first pane.
    static func sameKindOrLowest(_ location: ControlCallerLocation, kind: String) -> ControlPaneInfo? {
        let column = location.column.filter { !$0.tabs.isEmpty }
        if let same = column.last(where: { ControlCallerLocation.kinds(of: $0).contains(kind) }) { return same }
        return column.count > 1 ? column.last : nil
    }
}
