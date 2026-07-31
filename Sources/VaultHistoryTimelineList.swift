import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// SwiftUI bridge for the AppKit-virtualized History timeline.
struct VaultHistoryTimelineList: NSViewRepresentable {
    let groups: [VaultHistoryGroup]
    let workspaceSections: [VaultHistoryWorkspaceTimelineProjection.Section]
    let resumeEntriesByEventId: [String: SessionEntry]
    let availableClosedItemIds: Set<UUID>
    let actions: VaultHistoryRowActions
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent

    func makeCoordinator() -> VaultHistoryTableController {
        VaultHistoryTableController()
    }

    func makeNSView(context: Context) -> VaultHistoryTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ nsView: VaultHistoryTableContainerView, context: Context) {
        context.coordinator.apply(
            rows: workspaceSections.isEmpty
                ? Self.makeRows(
                    groups: groups,
                    resumeEntriesByEventId: resumeEntriesByEventId,
                    availableClosedItemIds: availableClosedItemIds,
                    actions: actions
                )
                : Self.makeWorkspaceRows(
                    sections: workspaceSections,
                    resumeEntriesByEventId: resumeEntriesByEventId,
                    availableClosedItemIds: availableClosedItemIds,
                    actions: actions
                ),
            actions: actions,
            globalFontMagnificationPercent: globalFontMagnificationPercent
        )
    }

    static func makeRows(
        groups: [VaultHistoryGroup],
        resumeEntriesByEventId: [String: SessionEntry],
        availableClosedItemIds: Set<UUID>,
        actions: VaultHistoryRowActions
    ) -> [VaultHistoryTableRow] {
        groups.flatMap { group in
            let groupAgent = group.id.hasPrefix("agent:")
                ? group.events.lazy.compactMap {
                    resolvedAgent(for: $0, resumeEntriesByEventId: resumeEntriesByEventId)
                }.first
                : nil
            let groupAction = groupRowAction(
                for: group,
                availableClosedItemIds: availableClosedItemIds,
                actions: actions
            )
            let header = VaultHistoryTableRow.group(
                id: group.id,
                title: group.title,
                count: group.events.count,
                agent: groupAgent,
                action: groupAction
            )
            let events = group.events.map { event in
                VaultHistoryTableRow.event(
                    event: event,
                    action: rowAction(
                        for: event,
                        resumeEntriesByEventId: resumeEntriesByEventId,
                        availableClosedItemIds: availableClosedItemIds,
                        actions: actions
                    ),
                    agent: resolvedAgent(
                        for: event,
                        resumeEntriesByEventId: resumeEntriesByEventId
                    )
                )
            }
            return [header] + events
        }
    }

    static func makeWorkspaceRows(
        sections: [VaultHistoryWorkspaceTimelineProjection.Section],
        resumeEntriesByEventId: [String: SessionEntry],
        availableClosedItemIds: Set<UUID>,
        actions: VaultHistoryRowActions
    ) -> [VaultHistoryTableRow] {
        sections.flatMap { section in
            var detailParts = [
                section.state == .active
                    ? String(localized: "vaultHistory.workspace.active", defaultValue: "Active")
                    : String(localized: "vaultHistory.workspace.closed", defaultValue: "Closed"),
            ]
            if let windowLabel = section.windowLabel {
                detailParts.append(windowLabel)
            }
            detailParts.append(terminalCountLabel(section.terminals.count))
            let headerAction: VaultHistoryRowAction? = {
                if section.state == .active,
                   let workspaceId = section.workspaceId,
                   actions.canActivateWorkspace {
                    return .activateWorkspace(workspaceId)
                }
                return section.closedItemId.flatMap { id in
                    guard actions.canReopen, availableClosedItemIds.contains(id) else {
                        return nil
                    }
                    return .reopenClosedItem(id)
                }
            }()
            let header = VaultHistoryTableRow.workspace(
                VaultHistoryTableRow.WorkspaceHeader(
                    id: section.id,
                    title: section.title,
                    detail: detailParts.joined(separator: " · "),
                    isActive: section.state == .active,
                    action: headerAction
                )
            )
            let topologyRows = section.terminals.flatMap { terminal -> [VaultHistoryTableRow] in
                let activeTerminalAction: VaultHistoryRowAction? = {
                    guard section.state == .active,
                          let workspaceId = section.workspaceId,
                          let terminalId = terminal.runtimeId,
                          actions.canActivateTerminal else {
                        return nil
                    }
                    return .activateTerminal(
                        workspaceId: workspaceId,
                        terminalId: terminalId
                    )
                }()
                let terminalTitle = VaultHistoryDisplayText.singleLine(terminal.title)
                let directory = terminal.directory.flatMap { rawValue -> String? in
                    let component = (rawValue as NSString).lastPathComponent
                    return component.isEmpty || component == "." ? nil : component
                }
                let terminalSubtitle = [
                    String(localized: "vaultHistory.terminal", defaultValue: "Terminal"),
                    directory,
                ].compactMap { $0 }.joined(separator: " · ")
                let terminalRow = VaultHistoryTableRow.topologyItem(
                    VaultHistoryTableRow.TopologyItem(
                        id: "terminal-row:\(section.id):\(terminal.id)",
                        title: terminalTitle.isEmpty
                            ? String(localized: "vaultHistory.terminal", defaultValue: "Terminal")
                            : terminalTitle,
                        subtitle: terminalSubtitle,
                        timestamp: nil,
                        icon: .system(name: "terminal", style: .secondary),
                        indentationLevel: 0,
                        action: activeTerminalAction,
                        accessibilityIdentifier: "VaultHistoryTerminalRow:\(terminal.id)"
                    )
                )
                let agentRows = terminal.agents.map { agent -> VaultHistoryTableRow in
                    let entry = agent.event.flatMap { resumeEntriesByEventId[$0.id] }
                    let action: VaultHistoryRowAction? = {
                        if let activeTerminalAction {
                            return activeTerminalAction
                        }
                        guard agent.state == .saved, let entry, actions.canResume else {
                            return nil
                        }
                        return .resumeSession(entry)
                    }()
                    let title = VaultHistoryDisplayText.singleLine(agent.title)
                    return .topologyItem(VaultHistoryTableRow.TopologyItem(
                        id: "agent-row:\(section.id):\(terminal.id):\(agent.id)",
                        title: title.isEmpty ? agent.agent.displayName : title,
                        subtitle: [
                            agent.agent.displayName,
                            agentStateLabel(agent.state),
                        ].joined(separator: " · "),
                        timestamp: agent.updatedAt,
                        icon: .agent(agent.agent),
                        indentationLevel: 1,
                        action: action,
                        accessibilityIdentifier: "VaultHistoryAgentRow:\(agent.id)"
                    ))
                }
                return [terminalRow] + agentRows
            }
            let activityRows = section.activityEvents.map { event in
                VaultHistoryTableRow.event(
                    event: event,
                    action: rowAction(
                        for: event,
                        resumeEntriesByEventId: resumeEntriesByEventId,
                        availableClosedItemIds: availableClosedItemIds,
                        actions: actions
                    ),
                    agent: resolvedAgent(
                        for: event,
                        resumeEntriesByEventId: resumeEntriesByEventId
                    )
                )
            }
            return [header] + topologyRows + activityRows
        }
    }

    private static func groupRowAction(
        for group: VaultHistoryGroup,
        availableClosedItemIds: Set<UUID>,
        actions: VaultHistoryRowActions
    ) -> VaultHistoryRowAction? {
        guard group.id.hasPrefix("workspace:"), actions.canReopen else { return nil }
        let recoverableEvent = group.events
            .filter { event in
                event.kind == .workspaceClosed
                    && event.subject.closedItemId.map(availableClosedItemIds.contains) == true
            }
            .max { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id < rhs.id
            }
        guard let closedItemId = recoverableEvent?.subject.closedItemId else { return nil }
        return .reopenClosedItem(closedItemId)
    }

    private static func resolvedAgent(
        for event: VaultHistoryEvent,
        resumeEntriesByEventId: [String: SessionEntry]
    ) -> SessionAgent? {
        resumeEntriesByEventId[event.id]?.agent
            ?? event.subject.agent.flatMap(SessionAgent.init(rawValue:))
    }

    private static func rowAction(
        for event: VaultHistoryEvent,
        resumeEntriesByEventId: [String: SessionEntry],
        availableClosedItemIds: Set<UUID>,
        actions: VaultHistoryRowActions
    ) -> VaultHistoryRowAction? {
        if let entry = resumeEntriesByEventId[event.id], actions.canResume {
            return .resumeSession(entry)
        }
        if let closedItemId = event.subject.closedItemId,
           availableClosedItemIds.contains(closedItemId),
           actions.canReopen {
            return .reopenClosedItem(closedItemId)
        }
        return nil
    }

    private static func terminalCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "vaultHistory.terminalCount.one", defaultValue: "1 terminal")
        }
        return String.localizedStringWithFormat(
            String(
                localized: "vaultHistory.terminalCount.other",
                defaultValue: "%d terminals"
            ),
            count
        )
    }

    private static func agentStateLabel(
        _ state: VaultHistoryWorkspaceTopology.AgentState
    ) -> String {
        switch state {
        case .running:
            return String(localized: "vaultHistory.agentState.running", defaultValue: "Running")
        case .restoring:
            return String(localized: "vaultHistory.agentState.restoring", defaultValue: "Restoring")
        case .hibernated:
            return String(localized: "vaultHistory.agentState.hibernated", defaultValue: "Hibernated")
        case .saved:
            return String(localized: "vaultHistory.agentState.saved", defaultValue: "Saved")
        }
    }
}

enum VaultHistoryTableRowID: Hashable {
    case group(String)
    case workspace(String)
    case topologyItem(String)
    case event(String)
}

enum VaultHistoryTableRow {
    enum IconStyle: Equatable {
        case secondary
        case active
    }

    enum Icon: Equatable {
        case system(name: String, style: IconStyle)
        case agent(SessionAgent)
    }

    struct WorkspaceHeader: Equatable {
        let id: String
        let title: String
        let detail: String
        let isActive: Bool
        let action: VaultHistoryRowAction?
    }

    struct TopologyItem: Equatable {
        let id: String
        let title: String
        let subtitle: String
        let timestamp: Date?
        let icon: Icon
        let indentationLevel: Int
        let action: VaultHistoryRowAction?
        let accessibilityIdentifier: String
    }

    case group(
        id: String,
        title: String,
        count: Int,
        agent: SessionAgent?,
        action: VaultHistoryRowAction?
    )
    case workspace(WorkspaceHeader)
    case topologyItem(TopologyItem)
    case event(event: VaultHistoryEvent, action: VaultHistoryRowAction?, agent: SessionAgent?)

    var id: VaultHistoryTableRowID {
        switch self {
        case .group(let id, _, _, _, _): return .group(id)
        case .workspace(let header): return .workspace(header.id)
        case .topologyItem(let item): return .topologyItem(item.id)
        case .event(let event, _, _): return .event(event.id)
        }
    }

    var isGroup: Bool {
        switch self {
        case .group, .workspace: return true
        case .topologyItem, .event: return false
        }
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        switch (self, other) {
        case let (
            .group(lhsID, lhsTitle, lhsCount, lhsAgent, lhsAction),
            .group(rhsID, rhsTitle, rhsCount, rhsAgent, rhsAction)
        ):
            return lhsID == rhsID
                && lhsTitle == rhsTitle
                && lhsCount == rhsCount
                && lhsAgent == rhsAgent
                && lhsAction == rhsAction
        case let (.event(lhsEvent, lhsAction, lhsAgent), .event(rhsEvent, rhsAction, rhsAgent)):
            return lhsEvent == rhsEvent && lhsAction == rhsAction && lhsAgent == rhsAgent
        case let (.workspace(lhs), .workspace(rhs)):
            return lhs == rhs
        case let (.topologyItem(lhs), .topologyItem(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

@MainActor
final class VaultHistoryTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("history")
    private weak var containerView: VaultHistoryTableContainerView?
    private var rows: [VaultHistoryTableRow] = []
    private var actions = VaultHistoryRowActions(onResume: nil, onReopenClosedItem: nil)
    private var globalFontMagnificationPercent = GlobalFontMagnification.defaultPercent
    private var pendingApply: ApplyInput?
    private var isFlushScheduled = false

    func makeContainerView() -> VaultHistoryTableContainerView {
        let container = VaultHistoryTableContainerView()
        containerView = container
        let table = container.tableView
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.floatsGroupRows = true
        table.setAccessibilityIdentifier("VaultHistoryTimeline")
        table.target = self
        table.doubleAction = #selector(handleDoubleClick(_:))

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = container.scrollView
        scrollView.documentView = table
        table.frame = scrollView.contentView.bounds
        table.autoresizingMask = [.width]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.applySidebarOverlayScrollerConfiguration()
        return container
    }

    func apply(
        rows: [VaultHistoryTableRow],
        actions: VaultHistoryRowActions,
        globalFontMagnificationPercent: Int
    ) {
        self.actions = actions
        pendingApply = ApplyInput(
            rows: rows,
            globalFontMagnificationPercent: globalFontMagnificationPercent
        )
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingApply() }
        }
    }

    private func flushPendingApply() {
        guard let input = pendingApply, let table = containerView?.tableView else {
            pendingApply = nil
            isFlushScheduled = false
            return
        }
        pendingApply = nil
        isFlushScheduled = false
        let previousRows = rows
        let presentationChanged = globalFontMagnificationPercent != input.globalFontMagnificationPercent
        let structuralChanged = previousRows.map(\.id) != input.rows.map(\.id)
        rows = input.rows
        globalFontMagnificationPercent = input.globalFontMagnificationPercent

        if structuralChanged || presentationChanged {
            table.reloadData()
            return
        }
        let changedRows = IndexSet(input.rows.indices.filter {
            !previousRows[$0].hasEquivalentContent(to: input.rows[$0])
        })
        guard !changedRows.isEmpty else { return }
        table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 36 }
        let base: CGFloat = rows[row].isGroup ? 26 : 38
        return max(base, GlobalFontMagnification.scaledSize(
            base,
            percent: globalFontMagnificationPercent
        ))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .group(let id, let title, let count, let agent, let action):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableGroupCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableGroupCellView) ?? VaultHistoryTableGroupCellView()
            cell.configure(
                id: id,
                title: title,
                count: count,
                agent: agent,
                action: action,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                onPerformAction: { [weak self] action in self?.actions.perform(action) }
            )
            return cell
        case .workspace(let header):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableGroupCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableGroupCellView) ?? VaultHistoryTableGroupCellView()
            cell.configureWorkspace(
                header,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                onPerformAction: { [weak self] action in self?.actions.perform(action) }
            )
            return cell
        case .topologyItem(let item):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableEventCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableEventCellView) ?? VaultHistoryTableEventCellView()
            cell.configure(
                topologyItem: item,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                onPerformAction: { [weak self] action in self?.actions.perform(action) }
            )
            return cell
        case .event(let event, let action, let agent):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableEventCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableEventCellView) ?? VaultHistoryTableEventCellView()
            cell.configure(
                event: event,
                action: action,
                agent: agent,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                onPerformAction: { [weak self] action in self?.actions.perform(action) }
            )
            return cell
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .event(_, let action?, _):
            actions.perform(action)
        case .topologyItem(let item):
            guard let action = item.action else { return }
            actions.perform(action)
        case .workspace(let header):
            guard let action = header.action else { return }
            actions.perform(action)
        case .group(_, _, _, _, let action?) :
            actions.perform(action)
        default:
            return
        }
    }

    private struct ApplyInput {
        let rows: [VaultHistoryTableRow]
        let globalFontMagnificationPercent: Int
    }
}

@MainActor
final class VaultHistoryTableContainerView: NSView {
    let scrollView = NSScrollView()
    let tableView = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
