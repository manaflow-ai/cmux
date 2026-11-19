import CmuxNextSettings
import Foundation

/// Where a run goes when its caller names no place (Lawrence 2026-11-12: agents opened tabs, browsers and viewers
/// in the workspace the person had focused, or in Home). What a caller runs stays in the caller's own workspace,
/// beside the caller; the app's focus is never the place. `action.run`, `file.open`, `browser.open_split`,
/// `browser.page.right` and the `beside` of `system.identify` and `snapshot.get` all read this one decision.
///
/// - A terminal no agent runs in (a person's shell, a script): its own pane, for a new terminal or a file.
/// - A browser from any terminal, an agent's or a person's, opens right of it (Lawrence 2026-11-15): the pane on
///   its right, else a new pane beside it. A window that shows the terminal measures it as a Cmd-click's
///   (TabLifecycle; the run is aimed at the terminal's own tab). A terminal no window shows has nothing to
///   measure: the columns here decide, as for an agent's chat off screen (the helper column's pane, never
///   another agent's home, else a new column right of the terminal, made with daemon commands).
/// - An agent (an agent chat, a Chief turn, a terminal whose hooks report an agent): its helper column, the column
///   right of its pane, unless that column is another agent's home (it holds another agent's chat, or a terminal an
///   agent runs in). Without a helper column, a new column directly right of its pane.
/// - An agent whose chat no tab shows stands in the workspace its session runs in (`caller.workspace`,
///   ``ControlCallerLocation/ownWorkspace(_:in:)``): what it opens is placed from that pane the same way. One
///   cmux cannot place at all is refused; nothing of an agent's lands in the focused workspace, Home (user, 2026-11-18).
/// - A docked chat (Home's, an agent chat's dock) keeps the strip beside it: a dock cannot split, and its strip is
///   where its tools open, so the strip's first column is its helper column whatever that column holds.
///
/// The topology knows columns, not frames: two panes split side by side in one column are one column here. The app
/// measures the column a window shows (AgentBesidePlacement) and takes ``agentHomes`` from this decision, so it
/// never places the caller's tab in a pane of another agent either.
struct ControlCallerPlacement: Sendable, Equatable {
    /// The wire names are `beside.placement`'s.
    enum Kind: String, Sendable {
        /// The helper column is there: a tab in it (the same-kind rule picks its pane).
        case helperColumn = "existing_column"
        /// No helper column: a new column directly right of the caller's pane.
        case newColumn = "new_column"
        /// No agent runs in the caller's terminal: a new terminal or file tab in its own pane (its browser
        /// still opens right of it, as any terminal's).
        case ownPane = "own_pane"
    }

    var location: ControlCallerLocation
    var kind: Kind
    /// The helper column's panes, top to bottom; empty unless `kind` is `helperColumn`.
    var column: [ControlPaneInfo] = []
    /// The panes of the caller's screen that are another agent's home, for an agent and for a plain
    /// terminal alike. Empty for a docked caller.
    var agentHomes: [String] = []

    /// `browserFromTerminal`: the decision for a browser the caller's terminal opens. It goes right of the
    /// terminal whoever runs there, so a terminal no agent runs in is placed as an agent's is.
    init(_ location: ControlCallerLocation, browserFromTerminal: Bool = false) {
        self.location = location
        var homes: [String] = []
        if location.pane.dock == nil {
            // The caller's own session: its own (an agent placed in its session's workspace stands at
            // another tab), else its chat tab's.
            let own = location.caller.agentSession ?? location.tab.agentSessionID
            homes = location.screen.panes.filter { pane in
                pane.id != location.pane.id && pane.tabs.contains { Self.isAnotherAgent($0, than: own) }
            }.map(\.id)
        }
        agentHomes = homes
        guard browserFromTerminal || Self.runsAgent(location) else {
            kind = .ownPane
            return
        }
        let beside = location.column
        let taken = beside.contains { homes.contains($0.id) }
        kind = beside.isEmpty || taken ? .newColumn : .helperColumn
        column = kind == .helperColumn ? beside : []
    }

    /// Whether the caller is an agent: an agent chat, a Chief turn, a terminal an agent runs in, or any caller
    /// whose request the cmux MCP server sent (`origin: mcp`: only an agent has one, also in a terminal whose
    /// hooks reported nothing).
    private static func runsAgent(_ location: ControlCallerLocation) -> Bool {
        location.caller.agentSession != nil || location.caller.homeChat || location.caller.viaMCP
            || location.tab.agentSessionID != nil || location.tab.runsAgent
    }

    /// Whether `tab` is the place of an agent other than the caller's session `own`: another session's chat
    /// (a subagent pane of the caller's own session is not), or a terminal an agent runs in.
    private static func isAnotherAgent(_ tab: ControlTabInfo, than own: String?) -> Bool {
        if let session = tab.agentSessionID { return session != own }
        return tab.runsAgent
    }

    /// Whether the placement is beside the caller (not in its own pane).
    var isBeside: Bool { kind != .ownPane }

    /// The helper column's pane for a new tab of `kind` (`terminal`, `browser`; nil for any other tab) when no
    /// window shows the column to measure (RightColumnPlacement): its lowest pane that holds the kind, else its
    /// lowest pane when it has two or more (never another split), else its first.
    func pane(for kind: String?) -> ControlPaneInfo? {
        let filled = column.filter { !$0.tabs.isEmpty }
        if let kind, let same = filled.last(where: { ControlCallerLocation.kinds(of: $0).contains(kind) }) { return same }
        return filled.count > 1 ? filled.last : column.first
    }

    /// A tab of `pane` a tab-target action can name: its selected tab, else its first.
    static func anchorTab(of pane: ControlPaneInfo) -> String? {
        if let selected = pane.selectedTabID, pane.tabs.contains(where: { $0.id == selected }) { return selected }
        return pane.tabs.first?.id
    }

    /// `beside` (`system.identify`, `snapshot.get`): the same decision, for the cmux CLI and MCP server, which
    /// place a new terminal from it (cmux-tui cli/beside.rs): a helper column with its panes and their kinds, a
    /// `null` pane with `new_column` (the CLI splits right of `caller.pane`), or the caller's own pane with
    /// `own_pane` and no `panes` (a tab there).
    var besideJSON: JSONValue {
        switch kind {
        case .ownPane:
            return ["pane": .string(location.pane.id), "placement": .string(kind.rawValue)]
        case .newColumn:
            return ["pane": .null, "placement": .string(kind.rawValue)]
        case .helperColumn:
            guard let beside = column.first else { return ["pane": .null, "placement": .string(Kind.newColumn.rawValue)] }
            // `panes`: the whole column, top to bottom, with the kinds each holds, so a terminal the CLI
            // or MCP server opens goes to the pane that already holds a terminal, or splits below a lone
            // pane of another kind.
            let panes: [JSONValue] = column.map { pane in
                ["id": .string(pane.id), "kinds": .array(ControlCallerLocation.kinds(of: pane).sorted().map(JSONValue.string))]
            }
            return ["pane": .string(beside.id), "column": beside.column.map { JSONValue($0) } ?? .null,
                    "placement": .string(kind.rawValue), "panes": .array(panes),
                    "selected_tab": .optional(beside.selectedTabID),
                    "tabs": .array(beside.tabs.map { tab in
                        ["id": .string(tab.id), "kind": .string(tab.page == nil ? tab.kind : "page"), "title": .string(tab.title),
                         "url": .optional(tab.url)]
                    })]
        }
    }
}

extension ControlTabInfo {
    /// Whether an agent runs in this tab's terminal now: its hooks reported one (`agent`, `agent_state`) and it
    /// has not ended (`done`). A terminal with no report is a person's shell or a script.
    var runsAgent: Bool {
        (agent != nil || agentState != nil) && agentState != "done"
    }
}
