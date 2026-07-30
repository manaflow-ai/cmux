import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// SwiftUI bridge for the AppKit-virtualized History timeline.
struct VaultHistoryTimelineList: NSViewRepresentable {
    let groups: [VaultHistoryGroup]
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
            rows: Self.makeRows(
                groups: groups,
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
            let header = VaultHistoryTableRow.group(
                id: group.id,
                title: group.title,
                count: group.events.count,
                agent: groupAgent
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
}

enum VaultHistoryTableRowID: Hashable {
    case group(String)
    case event(String)
}

enum VaultHistoryTableRow {
    case group(id: String, title: String, count: Int, agent: SessionAgent?)
    case event(event: VaultHistoryEvent, action: VaultHistoryRowAction?, agent: SessionAgent?)

    var id: VaultHistoryTableRowID {
        switch self {
        case .group(let id, _, _, _): return .group(id)
        case .event(let event, _, _): return .event(event.id)
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        switch (self, other) {
        case let (.group(lhsID, lhsTitle, lhsCount, lhsAgent), .group(rhsID, rhsTitle, rhsCount, rhsAgent)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsCount == rhsCount && lhsAgent == rhsAgent
        case let (.event(lhsEvent, lhsAction, lhsAgent), .event(rhsEvent, rhsAction, rhsAgent)):
            return lhsEvent == rhsEvent && lhsAction == rhsAction && lhsAgent == rhsAgent
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
        case .group(let id, let title, let count, let agent):
            let cell = (tableView.makeView(
                withIdentifier: VaultHistoryTableGroupCellView.reuseIdentifier,
                owner: self
            ) as? VaultHistoryTableGroupCellView) ?? VaultHistoryTableGroupCellView()
            cell.configure(
                id: id,
                title: title,
                count: count,
                agent: agent,
                globalFontMagnificationPercent: globalFontMagnificationPercent
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
        guard rows.indices.contains(row), case .event(_, let action?, _) = rows[row] else { return }
        actions.perform(action)
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
