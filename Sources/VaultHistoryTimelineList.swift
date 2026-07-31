import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure row projection used directly by the AppKit History controller.
enum VaultHistoryTimelineList {
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

    struct EventItem: Equatable {
        let id: String
        let title: String
        let titleTooltip: String
        let subtitle: String
        let timestamp: Date
        let icon: Icon
        let action: VaultHistoryRowAction?
        let agent: SessionAgent?
        let accessibilityIdentifier: String

        init(
            event: VaultHistoryEvent,
            action: VaultHistoryRowAction?,
            agent: SessionAgent?
        ) {
            id = event.id
            let normalizedTitle = VaultHistoryDisplayText.singleLine(event.title)
            if normalizedTitle.isEmpty {
                switch event.kind {
                case .windowOpened, .windowClosed:
                    title = String(localized: "vaultHistory.window", defaultValue: "Window")
                default:
                    title = String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
                }
            } else {
                title = normalizedTitle
            }
            titleTooltip = VaultHistoryDisplayText.singleLine(
                event.title,
                maximumLength: VaultHistoryDisplayText.tooltipMaximumLength
            )
            subtitle = Self.subtitle(for: event)
            timestamp = event.timestamp
            if event.kind == .sessionActivity, let agent {
                icon = .agent(agent)
            } else {
                icon = .system(name: event.kind.symbolName, style: .secondary)
            }
            self.action = action
            self.agent = agent
            accessibilityIdentifier = "VaultHistoryEventRow:\(event.id)"
        }

        private static func subtitle(for event: VaultHistoryEvent) -> String {
            var parts: [String] = []
            if event.kind == .sessionActivity {
                if let displayName = event.subject.agentDisplayName, !displayName.isEmpty {
                    parts.append(VaultHistoryDisplayText.singleLine(displayName))
                } else if let raw = event.subject.agent, let agent = SessionAgent(rawValue: raw) {
                    parts.append(agent.displayName)
                } else {
                    parts.append(event.kind.label)
                }
            } else {
                parts.append(event.kind.label)
            }
            if event.kind == .workspaceRenamed,
               let previousTitle = event.previousTitle,
               !previousTitle.isEmpty {
                parts.append(String(
                    format: String(
                        localized: "vaultHistory.detail.renamedFrom",
                        defaultValue: "was “%@”"
                    ),
                    VaultHistoryDisplayText.singleLine(previousTitle)
                ))
            }
            if let count = event.workspaceCount {
                parts.append(workspaceCountLabel(count))
            }
            if let directory = event.subject.directory, !directory.isEmpty {
                let component = (directory as NSString).lastPathComponent
                if !component.isEmpty, component != "." {
                    parts.append(VaultHistoryDisplayText.singleLine(component))
                }
            }
            return VaultHistoryDisplayText.singleLine(parts.joined(separator: " · "))
        }

        private static func workspaceCountLabel(_ count: Int) -> String {
            if count == 1 {
                return String(
                    localized: "vaultHistory.workspaceCount.one",
                    defaultValue: "1 workspace"
                )
            }
            return String.localizedStringWithFormat(
                String(
                    localized: "vaultHistory.workspaceCount.other",
                    defaultValue: "%d workspaces"
                ),
                count
            )
        }
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
    case event(EventItem)

    static func event(
        event: VaultHistoryEvent,
        action: VaultHistoryRowAction?,
        agent: SessionAgent?
    ) -> Self {
        .event(EventItem(event: event, action: action, agent: agent))
    }

    var id: VaultHistoryTableRowID {
        switch self {
        case .group(let id, _, _, _, _): return .group(id)
        case .workspace(let header): return .workspace(header.id)
        case .topologyItem(let item): return .topologyItem(item.id)
        case .event(let item): return .event(item.id)
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
        case let (.event(lhs), .event(rhs)):
            return lhs == rhs
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
final class VaultHistoryTableController: NSObject, NSTableViewDelegate {
    private enum Section: Hashable {
        case main
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("history")
    private weak var containerView: VaultHistoryTableContainerView?
    private var dataSource: NSTableViewDiffableDataSource<Section, VaultHistoryTableRowID>?
    private var rowByID: [VaultHistoryTableRowID: VaultHistoryTableRow] = [:]
    private var actions = VaultHistoryRowActions(onResume: nil, onReopenClosedItem: nil)
    private var globalFontMagnificationPercent = GlobalFontMagnification.defaultPercent
    private var pendingApply: ApplyInput?
    private var isFlushScheduled = false

    func makeContainerView() -> VaultHistoryTableContainerView {
        let container = VaultHistoryTableContainerView()
        containerView = container
        let table = container.tableView
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

        let dataSource = NSTableViewDiffableDataSource<Section, VaultHistoryTableRowID>(
            tableView: table
        ) { [weak self] tableView, _, _, identifier in
            guard let self, let row = self.rowByID[identifier] else {
                return NSTableCellView()
            }
            return self.makeCell(tableView: tableView, row: row)
        }
        dataSource.defaultRowAnimation = []
        self.dataSource = dataSource

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
        guard let input = pendingApply, let dataSource else {
            pendingApply = nil
            isFlushScheduled = false
            return
        }
        pendingApply = nil
        isFlushScheduled = false
        let identifiers = input.rows.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            assertionFailure("History rows must have unique identifiers")
            return
        }

        let previousRowByID = rowByID
        let currentIdentifiers = dataSource.snapshot().itemIdentifiers
        let currentIdentifierSet = Set(currentIdentifiers)
        let nextRowByID = Dictionary(uniqueKeysWithValues: input.rows.map { ($0.id, $0) })
        let presentationChanged = globalFontMagnificationPercent != input.globalFontMagnificationPercent
        let changedIdentifiers = identifiers.filter { identifier in
            guard currentIdentifierSet.contains(identifier),
                  let previousRow = previousRowByID[identifier],
                  let nextRow = nextRowByID[identifier] else {
                return false
            }
            return presentationChanged || !previousRow.hasEquivalentContent(to: nextRow)
        }

        rowByID = nextRowByID
        globalFontMagnificationPercent = input.globalFontMagnificationPercent
        guard currentIdentifiers != identifiers || !changedIdentifiers.isEmpty else { return }

        var snapshot = NSDiffableDataSourceSnapshot<Section, VaultHistoryTableRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(identifiers, toSection: .main)
        snapshot.reloadItems(changedIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableRow(at: row)?.isGroup == true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let row = tableRow(at: row) else { return 36 }
        let base: CGFloat = row.isGroup ? 26 : 38
        return max(base, GlobalFontMagnification.scaledSize(
            base,
            percent: globalFontMagnificationPercent
        ))
    }

    private func makeCell(tableView: NSTableView, row: VaultHistoryTableRow) -> NSView {
        switch row {
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
        case .event(let item):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableEventCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableEventCellView) ?? VaultHistoryTableEventCellView()
            cell.configure(
                eventItem: item,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                onPerformAction: { [weak self] action in self?.actions.perform(action) }
            )
            return cell
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        guard let row = tableRow(at: sender.clickedRow) else { return }
        switch row {
        case .event(let item):
            guard let action = item.action else { return }
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

    private func tableRow(at index: Int) -> VaultHistoryTableRow? {
        guard index >= 0,
              let identifier = dataSource?.itemIdentifier(forRow: index) else {
            return nil
        }
        return rowByID[identifier]
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
