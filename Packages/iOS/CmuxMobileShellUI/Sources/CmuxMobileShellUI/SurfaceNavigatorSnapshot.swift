import CmuxAgentChat
import CmuxMobileShellModel
import Foundation
import SwiftUI

/// Immutable per-render snapshot driving the surface strip, the surface
/// pager, and the workspace map. Built from the workspace preview, the
/// phone's selection, and the workspace's chat sessions; the views below it
/// hold no store references (snapshot-boundary rule).
struct SurfaceNavigatorSnapshot: Equatable {
    /// Live agent state shown on a chip/pane, reduced to what triage needs.
    enum AgentStatus: Equatable {
        case none
        case working
        case needsInput

        /// Attention rank when multiple sessions share a terminal.
        var triageRank: Int {
            switch self {
            case .none: 0
            case .working: 1
            case .needsInput: 2
            }
        }
    }

    /// Theme-derived chrome colors for the navigator views (strip, map,
    /// placeholder pages), captured as plain values so the views stay
    /// store-free. Built from the live terminal theme by the bridge, and from
    /// fixed Monokai constants by the fixture.
    struct Palette: Equatable {
        let background: Color
        let foreground: Color
        var dimForeground: Color { foreground.opacity(0.78) }
    }

    /// One tab chip.
    struct Chip: Equatable, Identifiable {
        let id: MobileTerminalPreview.ID
        let title: String
        let kind: MobileWorkspacePaneLayout.Tab.Kind
        let status: AgentStatus
        let isSelected: Bool
        let isReady: Bool
    }

    /// One pane's chips, in the pane's tab order.
    struct PaneGroup: Equatable, Identifiable {
        let id: MobileWorkspacePaneLayout.Pane.ID
        let chips: [Chip]
    }

    /// Pane groups in the Mac's spatial (depth-first) order.
    let groups: [PaneGroup]
    /// The tab the pager is showing (terminal selection, or a non-terminal
    /// tab being previewed).
    let selectedTabID: MobileTerminalPreview.ID?
    /// The resolved layout tree (reported by the Mac, or the single-pane
    /// fallback), for the map and the layout glyph.
    let layout: MobileWorkspacePaneLayout
    /// Whether closing a tab is currently allowed (more than one terminal).
    let canCloseTab: Bool
    /// Theme-derived chrome colors.
    let palette: Palette

    /// Chips across every pane, in spatial order — the pager's page order.
    var orderedChips: [Chip] {
        groups.flatMap(\.chips)
    }

    /// The pane containing the selected tab (the strip's "+" target).
    var selectedPaneID: MobileWorkspacePaneLayout.Pane.ID? {
        guard let selectedTabID else { return groups.first?.id }
        return groups.first { group in group.chips.contains { $0.id == selectedTabID } }?.id
            ?? groups.first?.id
    }

    /// Build the snapshot for one workspace.
    ///
    /// The layout tree is the Mac-reported structure when available, else a
    /// synthesized single pane over the flat terminals. Terminal-kind tabs
    /// prefer the flat row's title/readiness (the two agree on a settled
    /// sync; the flat row also reflects optimistic local mutations). Tabs
    /// that exist only in the flat list (a mid-sync race) are appended to the
    /// last pane so no terminal is ever unreachable.
    static func build(
        workspace: MobileWorkspacePreview,
        selectedTabID: MobileTerminalPreview.ID?,
        sessions: [ChatSessionDescriptor],
        palette: Palette
    ) -> SurfaceNavigatorSnapshot {
        var layout = workspace.paneLayout
            ?? .singlePane(terminals: workspace.terminals)
        let terminalsByID = Dictionary(
            uniqueKeysWithValues: workspace.terminals.map { ($0.id, $0) }
        )
        let layoutTabIDs = Set(layout.orderedTabs.map(\.id))
        let straggled = workspace.terminals.filter { !layoutTabIDs.contains($0.id) }
        if !straggled.isEmpty {
            layout = layout.appendingTerminalsToLastPane(straggled)
        }

        // needsInput outranks working outranks none when two sessions share a
        // terminal.
        let statusByTerminalID: [String: AgentStatus] = sessions.reduce(into: [:]) { result, session in
            guard let terminalID = session.terminalID else { return }
            let status: AgentStatus
            switch session.state {
            case .working: status = .working
            case .needsInput: status = .needsInput
            case .idle, .ended: status = .none
            }
            if status.triageRank > (result[terminalID] ?? AgentStatus.none).triageRank {
                result[terminalID] = status
            }
        }

        let resolvedSelection = selectedTabID
            ?? workspace.terminals.first(where: \.isFocused)?.id
            ?? layout.orderedTabs.first?.id
        let groups = layout.panes.map { pane in
            PaneGroup(
                id: pane.id,
                chips: pane.tabs.map { tab in
                    let terminal = terminalsByID[tab.id]
                    return Chip(
                        id: tab.id,
                        title: terminal?.name ?? tab.title,
                        kind: tab.kind,
                        status: statusByTerminalID[tab.id.rawValue] ?? .none,
                        isSelected: tab.id == resolvedSelection,
                        isReady: terminal?.isReady ?? true
                    )
                }
            )
        }
        return SurfaceNavigatorSnapshot(
            groups: groups,
            selectedTabID: resolvedSelection,
            layout: layout,
            canCloseTab: workspace.terminals.count > 1,
            palette: palette
        )
    }
}

extension MobileWorkspacePaneLayout {
    /// A copy with `terminals` appended as terminal tabs to the LAST pane.
    /// Used only for mid-sync stragglers (a terminal present in the flat list
    /// but not yet in the reported layout).
    func appendingTerminalsToLastPane(
        _ terminals: [MobileTerminalPreview]
    ) -> MobileWorkspacePaneLayout {
        let extraTabs = terminals.map { terminal in
            Tab(id: terminal.id, kind: .terminal, title: terminal.name)
        }
        guard let lastPaneID = panes.last?.id else { return self }
        return MobileWorkspacePaneLayout(
            root: Self.appendTabs(extraTabs, toPane: lastPaneID, in: root)
        )
    }

    private static func appendTabs(
        _ tabs: [Tab],
        toPane paneID: Pane.ID,
        in node: Node
    ) -> Node {
        switch node {
        case .pane(var pane):
            guard pane.id == paneID else { return node }
            pane.tabs.append(contentsOf: tabs)
            return .pane(pane)
        case let .split(orientation, ratio, first, second):
            return .split(
                orientation: orientation,
                ratio: ratio,
                first: appendTabs(tabs, toPane: paneID, in: first),
                second: appendTabs(tabs, toPane: paneID, in: second)
            )
        }
    }
}

/// The action bundle the strip/pager/map invoke. Pure closures so the views
/// below the snapshot boundary never touch the store.
struct SurfaceNavigatorActions {
    var selectTab: (MobileTerminalPreview.ID) -> Void
    var closeTab: (MobileTerminalPreview.ID) -> Void
    var newTab: (MobileWorkspacePaneLayout.Pane.ID?) -> Void
    var openMap: () -> Void
}
