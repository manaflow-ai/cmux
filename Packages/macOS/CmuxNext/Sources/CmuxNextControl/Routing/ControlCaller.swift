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

    init(agentSession: String? = nil, terminalID: String? = nil) {
        self.agentSession = agentSession
        self.terminalID = terminalID
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
        guard agentSession != nil || terminalID != nil else { return nil }
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

    /// The caller's chat tab (agent session) or terminal tab, nil when the
    /// topology shows neither.
    static func resolve(_ caller: ControlCaller, in topology: ControlTopology) -> Self? {
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
                                beside: besidePane(of: pane, on: screen))
                }
            }
        }
        return nil
    }

    /// The first pane of the next column right of `pane` (`column`, as the
    /// window draws columns left to right).
    static func besidePane(of pane: ControlPaneInfo, on screen: ControlScreenInfo) -> ControlPaneInfo? {
        guard let column = pane.column else { return nil }
        return screen.panes.first { $0.column == column + 1 }
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
        return ["pane": .string(beside.id), "column": beside.column.map { JSONValue($0) } ?? .null, "placement": "existing_column",
                "selected_tab": .optional(beside.selectedTabID),
                "tabs": .array(beside.tabs.map { tab in
                    ["id": .string(tab.id), "kind": .string(tab.page == nil ? tab.kind : "page"), "title": .string(tab.title),
                     "url": .optional(tab.url)]
                })]
    }

    /// `members` with `caller` and `beside` for `params`' caller, when the
    /// topology shows it (`snapshot.get`, `system.identify`).
    static func annotate(_ members: inout [String: JSONValue], params: [String: JSONValue], topology: ControlTopology) throws {
        guard let caller = try ControlCaller(params) else { return }
        guard let location = resolve(caller, in: topology) else {
            members["caller"] = ["is_caller": true, "agent_session": .optional(caller.agentSession),
                                 "terminal_id": .optional(caller.terminalID), "found": false]
            return
        }
        members["caller"] = location.callerJSON
        members["beside"] = location.besideJSON
    }
}

extension ControlRouter {
    /// The actions `beside_caller` places (phase 1: the browser and the diff viewer).
    static let besideCallerActions: Set<String> = ["openBrowser", "openDiffViewer"]

    /// Aims an agent's surface-opening run that names no target at the
    /// column right of its chat (beside_caller). An explicit target wins;
    /// a caller the topology does not show leaves the run as it is.
    static func placeBesideCaller(_ request: inout ControlActionRequest, action: ControlActionInfo,
                                  params: [String: JSONValue], topology: ControlTopology) throws {
        guard besideCallerActions.contains(action.id), request.target == nil,
              let caller = try ControlCaller(params), caller.agentSession != nil,
              let location = ControlCallerLocation.resolve(caller, in: topology) else { return }
        let paneTarget = action.targets.contains("pane")
        if let beside = location.beside {
            if paneTarget {
                request.target = ControlTargetRef(kind: "pane", id: beside.id)
            } else if let tab = location.besideTab {
                request.target = ControlTargetRef(kind: "tab", id: tab)
            } else {
                return
            }
        } else {
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
}
