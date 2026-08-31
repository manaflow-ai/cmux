import AppKit
import Bonsplit
import CmuxFoundation
import SwiftUI

/// Right-sidebar Harbor panel. The outline keeps the hierarchy host → tool
/// session → workspace/window → terminal, while every terminal leaf carries a
/// live attach capability for the existing pane-drop router.
struct HarborPanelView: View {
    let tabManager: TabManager
    let chromeBackgroundColor: NSColor

    @StateObject private var viewModel = HarborPanelViewModel()
    @State private var isAddHostPresented = false
    @State private var newHostDestination = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .rightSidebarChromeBar()
                .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            if !TuiTerminalAttachBridge.isManualIOEnabled {
                manualIOOffNotice
            }
            HarborTreeOutlineView(
                snapshots: viewModel.snapshots,
                onAttach: attach,
                onRemoveHost: viewModel.removeHost,
                onRefresh: viewModel.refresh
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .accessibilityIdentifier("HarborPanel")
    }

    private var header: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            Text(String(localized: "harbor.header.title", defaultValue: "Harbor"))
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                isAddHostPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help(String(localized: "harbor.action.addHost", defaultValue: "Add SSH Host…"))
            .accessibilityIdentifier("HarborAddHostButton")
            .popover(isPresented: $isAddHostPresented, arrowEdge: .bottom) {
                addHostPopover
            }
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(String(localized: "harbor.action.refresh", defaultValue: "Refresh"))
            .accessibilityIdentifier("HarborRefreshButton")
        }
    }

    private var addHostPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "harbor.addHost.title", defaultValue: "Add SSH Host"))
                .cmuxFont(size: 12, weight: .semibold)
            TextField(
                String(localized: "harbor.addHost.placeholder", defaultValue: "user@host or ssh alias"),
                text: $newHostDestination
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .onSubmit(submitNewHost)
            HStack {
                Spacer()
                Button(String(localized: "harbor.addHost.add", defaultValue: "Add"), action: submitNewHost)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!HarborHostStore.isPlausibleDestination(
                        newHostDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
            }
        }
        .padding(12)
    }

    private var manualIOOffNotice: some View {
        Text(String(
            localized: "harbor.notice.manualIOOff",
            defaultValue: "Manual IO beta is off. Harbor drops open in a plain terminal instead of a daemon-backed pane."
        ))
        .cmuxFont(size: 11)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    private func submitNewHost() {
        if viewModel.addHost(newHostDestination) {
            newHostDestination = ""
            isAddHostPresented = false
        }
    }

    @MainActor
    private func attach(_ item: HarborDragItem) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId }) else {
            NSSound.beep()
            return
        }
        if !workspace.attachHarborItemInFocusedPane(item: item) {
            NSSound.beep()
        }
    }
}

/// AppKit bridge for the Harbor outline. A native outline is used instead of
/// a lazy SwiftUI list so disclosure state, row identity, context menus, and
/// the existing Bonsplit drag payload all share one lifecycle.
struct HarborTreeOutlineView: NSViewRepresentable {
    let snapshots: [HarborHostSnapshot]
    let onAttach: @MainActor (HarborDragItem) -> Void
    let onRemoveHost: @MainActor (String) -> Void
    let onRefresh: @MainActor () -> Void

    @Environment(\.tabDragTransferRegistry) private var tabDragTransferRegistry
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onAttach: onAttach,
            onRemoveHost: onRemoveHost,
            onRefresh: onRefresh,
            tabDragTransferRegistry: { [tabDragTransferRegistry] in
                tabDragTransferRegistry ?? AppDelegate.shared?.tabDragTransferRegistry
            }
        )
    }

    func makeNSView(context: Context) -> HarborTreeContainerView {
        let container = HarborTreeContainerView(coordinator: context.coordinator)
        container.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return container
    }

    func updateNSView(_ container: HarborTreeContainerView, context: Context) {
        container.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        context.coordinator.onAttach = onAttach
        context.coordinator.onRemoveHost = onRemoveHost
        context.coordinator.onRefresh = onRefresh
        context.coordinator.apply(nodes: HarborTreeNodeBuilder.nodes(from: snapshots))
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var onAttach: @MainActor (HarborDragItem) -> Void
        var onRemoveHost: @MainActor (String) -> Void
        var onRefresh: @MainActor () -> Void
        private let tabDragTransferRegistry: @MainActor () -> TabDragTransferRegistry?
        weak var outlineView: CloudTreeNSOutlineView?
        private var nodes: [HarborTreeNode] = []
        private var structureSignature: [String] = []
        private var contentSignature: [String] = []
        private var selectedNodeID: String?
        private var expandedIDs = Set<String>()
        private var activeDrag: (id: UUID, registration: TabDragTransferRegistration)?
        private var isUpdating = false
        private var userChangedExpansion = false

        init(
            onAttach: @escaping @MainActor (HarborDragItem) -> Void,
            onRemoveHost: @escaping @MainActor (String) -> Void,
            onRefresh: @escaping @MainActor () -> Void,
            tabDragTransferRegistry: @escaping @MainActor () -> TabDragTransferRegistry?
        ) {
            self.onAttach = onAttach
            self.onRemoveHost = onRemoveHost
            self.onRefresh = onRefresh
            self.tabDragTransferRegistry = tabDragTransferRegistry
        }

        func apply(nodes: [HarborTreeNode]) {
            let nextStructure = HarborTreeNodeBuilder.structureSignature(nodes)
            let nextContent = HarborTreeNodeBuilder.contentSignature(nodes)
            guard nextStructure != structureSignature || nextContent != contentSignature else { return }
            contentSignature = nextContent
            if nextStructure == structureSignature, !self.nodes.isEmpty {
                for (old, new) in zip(self.nodes, nodes) { old.adopt(from: new) }
                guard let outlineView, outlineView.numberOfRows > 0 else { return }
                withUpdate {
                    outlineView.reloadData(
                        forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
                return
            }
            self.nodes = nodes
            structureSignature = nextStructure
            let hasAttachableContent = HarborTreeNodeBuilder.flattened(nodes).contains { node in
                switch node.kind {
                case .session, .windowGroup, .terminal: return true
                case .host, .placeholder: return false
                }
            }
            if !userChangedExpansion, hasAttachableContent {
                // Harbor is a catalog, so show the complete hierarchy while
                // asynchronous host probes are still adding sessions. The
                // first result may contain only one tool, so expand newly
                // discovered branches until the user changes disclosure.
                expandedIDs.formUnion(
                    HarborTreeNodeBuilder.flattened(nodes)
                        .filter(\.isExpandable)
                        .map(\.id)
                )
            }
            guard let outlineView else { return }
            withUpdate {
                outlineView.reloadData()
                restoreExpansion()
                restoreSelection()
            }
        }

        private func withUpdate(_ body: () -> Void) {
            isUpdating = true
            body()
            isUpdating = false
        }

        private func restoreExpansion() {
            guard let outlineView else { return }
            for node in HarborTreeNodeBuilder.flattened(nodes) where node.isExpandable && expandedIDs.contains(node.id) {
                outlineView.expandItem(node)
            }
        }

        private func restoreSelection() {
            guard let outlineView, let selectedNodeID else { return }
            for row in 0..<outlineView.numberOfRows {
                if (outlineView.item(atRow: row) as? HarborTreeNode)?.id == selectedNodeID {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }

        // MARK: NSOutlineView data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? HarborTreeNode)?.children.count ?? nodes.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? HarborTreeNode)?.children[index] ?? nodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? HarborTreeNode)?.isExpandable ?? false
        }

        // MARK: Rows and state

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? HarborTreeNode else { return nil }
            let cell = (outlineView.makeView(withIdentifier: HarborTreeCellView.identifier, owner: nil) as? HarborTreeCellView)
                ?? HarborTreeCellView(frame: .zero)
            cell.configure(node: node)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            CloudTreeRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? HarborTreeNode else { return 24 }
            switch node.kind {
            case .host: return 34
            case .terminal(_, _, let info):
                return info.agent == nil && info.cwd == nil ? 25 : 34
            case .session, .windowGroup, .placeholder: return 25
            }
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let outlineView else { return }
            selectedNodeID = outlineView.selectedRow >= 0
                ? (outlineView.item(atRow: outlineView.selectedRow) as? HarborTreeNode)?.id
                : nil
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isUpdating, let node = notification.userInfo?["NSObject"] as? HarborTreeNode else { return }
            userChangedExpansion = true
            expandedIDs.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isUpdating, let node = notification.userInfo?["NSObject"] as? HarborTreeNode else { return }
            userChangedExpansion = true
            expandedIDs.remove(node.id)
        }

        // MARK: Open and keyboard

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? HarborTreeNode else { return }
            open(node)
        }

        func openSelection() {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? HarborTreeNode else { return }
            open(node)
        }

        private func open(_ node: HarborTreeNode) {
            if let item = node.dragItem {
                onAttach(item)
            } else if node.isExpandable {
                toggle(node)
            }
        }

        private func toggle(_ node: HarborTreeNode) {
            guard let outlineView else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }

        func moveSelection(by delta: Int) {
            guard let outlineView, outlineView.numberOfRows > 0 else { return }
            let current = outlineView.selectedRow >= 0 ? outlineView.selectedRow : (delta >= 0 ? -1 : outlineView.numberOfRows)
            let target = min(max(current + delta, 0), outlineView.numberOfRows - 1)
            outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            outlineView.scrollRowToVisible(target)
        }

        func performDisclosure(_ action: RightSidebarKeyboardNavigation.DisclosureAction) {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? HarborTreeNode else { return }
            switch action {
            case .expand:
                if node.isExpandable, !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                else { moveSelection(by: 1) }
            case .collapse:
                if node.isExpandable, outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
                else if let parent = outlineView.parent(forItem: node) as? HarborTreeNode {
                    let row = outlineView.row(forItem: parent)
                    if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                }
            }
        }

        func selectQuickSearchMatch(query: String) {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty, let outlineView else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? HarborTreeNode else { continue }
                if node.searchableTitle.lowercased().contains(needle) {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                    return
                }
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? HarborTreeNode else { return }
            for menuItem in menuItems(for: node) { menu.addItem(menuItem) }
        }

        private func menuItems(for node: HarborTreeNode) -> [NSMenuItem] {
            switch node.kind {
            case .host(let host, _):
                var items = [harborMenuItem(String(localized: "harbor.menu.refresh", defaultValue: "Refresh")) { [onRefresh] in onRefresh() }]
                if case .ssh(let destination) = host {
                    items.append(harborMenuItem(String(localized: "harbor.host.remove", defaultValue: "Remove Host")) { [onRemoveHost] in onRemoveHost(destination) })
                }
                return items
            case .session(let host, let info):
                var items: [NSMenuItem] = []
                if let item = node.dragItem {
                    items.append(harborMenuItem(String(localized: "harbor.row.attach", defaultValue: "Attach in Current Workspace")) { [onAttach] in onAttach(item) })
                } else {
                    let item = HarborDragItem.sessionTUI(host: host, tool: info.tool, sessionName: info.name, state: info.state)
                    items.append(harborMenuItem(String(localized: "harbor.menu.attachSession", defaultValue: "Attach Session")) { [onAttach] in onAttach(item) })
                }
                items.append(harborMenuItem(String(localized: "harbor.menu.copyCommand", defaultValue: "Copy Attach Command")) {
                    [self] in
                    self.copy(HarborAttachCommand.shellCommand(host: host, tool: info.tool, name: info.name, state: info.state))
                })
                return items
            case .terminal(_, _, _):
                guard let item = node.dragItem else { return [] }
                return [
                    harborMenuItem(String(localized: "harbor.row.attach", defaultValue: "Attach in Current Workspace")) { [onAttach] in onAttach(item) },
                    harborMenuItem(String(localized: "harbor.menu.copyCommand", defaultValue: "Copy Attach Command")) { [self] in self.copy(HarborAttachCommand.shellCommand(for: item)) },
                ]
            case .windowGroup, .placeholder:
                return []
            }
        }

        private func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private func harborMenuItem(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = HarborTreeMenuItem(title: title, action: action)
            item.target = item
            return item
        }

        // MARK: Native drag

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? HarborTreeNode,
                  let dragItem = node.dragItem,
                  let registry = tabDragTransferRegistry(),
                  let app = AppDelegate.shared else { return nil }
            let dragID = app.harborSessionDragRegistry.register(dragItem)
            guard let registration = registry.register(TabDragTransfer(
                tab: Bonsplit.Tab(
                    id: TabID(uuid: dragID),
                    title: dragItem.title,
                    icon: "terminal.fill",
                    kind: "terminal"
                ),
                sourcePaneId: PaneID(id: dragID)
            )) else {
                app.harborSessionDragRegistry.discard(id: dragID)
                return nil
            }
            activeDrag = (dragID, registration)
#if DEBUG
            cmuxDebugLog("harbor.drag.begin id=\(dragID.uuidString.prefix(5)) item=\(dragItem.title)")
#endif
            return registration.pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {}

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let activeDrag else { return }
            tabDragTransferRegistry()?.end(activeDrag.registration)
            AppDelegate.shared?.harborSessionDragRegistry.discard(id: activeDrag.id)
            activeDrag.registration.clearResidualCapability(from: NSPasteboard(name: .drag))
            self.activeDrag = nil
        }
    }
}

/// Scroll container for the Harbor outline.
final class HarborTreeContainerView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = CloudTreeNSOutlineView()

    init(coordinator: HarborTreeOutlineView.Coordinator) {
        super.init(frame: .zero)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 16
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.setAccessibilityIdentifier("HarborTree")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("harbor.node"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(HarborTreeOutlineView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        outlineView.onMoveSelection = { [weak coordinator] delta in coordinator?.moveSelection(by: delta) }
        outlineView.onDisclosure = { [weak coordinator] action in coordinator?.performDisclosure(action) }
        outlineView.onQuickSearch = { [weak coordinator] query in coordinator?.selectQuickSearchMatch(query: query) }
        outlineView.onDidBecomeFirstResponder = { [weak coordinator] in
            guard let coordinator, let window = coordinator.outlineView?.window else { return }
            AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .harbor, in: window)
        }
        coordinator.outlineView = outlineView

        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Host SwiftUI row content while leaving all pointer events to AppKit.
final class HarborTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HarborTreeCell")
    private let displayHost = HarborPassthroughHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        displayHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(displayHost)
        NSLayoutConstraint.activate([
            displayHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            displayHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            displayHost.topAnchor.constraint(equalTo: topAnchor),
            displayHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(node: HarborTreeNode) {
        displayHost.rootView = AnyView(
            HarborTreeRowContent(kind: node.kind)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
        setAccessibilityLabel(node.searchableTitle)
        setAccessibilityIdentifier("HarborRow.\(node.id)")
        toolTip = node.searchableTitle
    }
}

final class HarborPassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Compact two-line row content. Agent state is shown before terminal title so
/// blocked or working sessions remain visible while the command line changes.
struct HarborTreeRowContent: View {
    let kind: HarborTreeNode.Kind

    var body: some View {
        switch kind {
        case .host(let host, let status): hostRow(host: host, status: status)
        case .session(let host, let info): sessionRow(host: host, info: info)
        case .windowGroup(let label): simpleRow(icon: "folder", tint: .blue, title: label, detail: nil)
        case .terminal(let host, let tool, let info): terminalRow(host: host, tool: tool, info: info)
        case .placeholder(let text): simpleRow(icon: "info.circle", tint: .secondary, title: text, detail: nil, dimmed: true)
        }
    }

    private func hostRow(host: HarborHostRef, status: HarborHostSnapshot.Status) -> some View {
        let subtitle: String
        switch status {
        case .loading: subtitle = String(localized: "harbor.refreshing", defaultValue: "Scanning…")
        case .loaded: subtitle = String(localized: "harbor.host.ready", defaultValue: "Ready")
        case .unreachable(let reason):
            subtitle = String(format: String(localized: "harbor.host.unreachable", defaultValue: "Unreachable: %@"), reason)
        }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: host.isLocal ? "laptopcomputer" : "network")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .cmuxFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                Text(subtitle)
                    .cmuxFont(size: 10)
                    .foregroundStyle(statusColor(status))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 6)
    }

    private func sessionRow(host: HarborHostRef, info: HarborSessionInfo) -> some View {
        let terminalCount = info.windows.reduce(0) { $0 + $1.terminals.count } + info.looseTerminals.count
        let detail = terminalCount > 0
            ? String(format: String(localized: "harbor.session.terminalCount", defaultValue: "%d terminals · %@"), terminalCount, info.state.label)
            : info.state.label
        return simpleRow(
            icon: info.tool.symbolName,
            tint: toolColor(info.tool),
            title: info.name,
            detail: "\(info.tool.displayName) · \(detail)"
        )
    }

    private func terminalRow(host: HarborHostRef, tool: HarborTool, info: HarborTerminalInfo) -> some View {
        let primary = info.agent?.displayName ?? (info.title.isEmpty ? info.shortID : info.title)
        let secondary: String? = {
            if let message = info.agent?.message, !message.isEmpty { return message }
            if let cwd = info.cwd, !cwd.isEmpty { return abbreviated(cwd) }
            if let agent = info.agent { return agent.state.label }
            return nil
        }()
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: info.isActive ? "terminal.fill" : "terminal")
                .font(.system(size: 10.5))
                .foregroundStyle(toolColor(tool))
                .frame(width: 15, height: 17)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(primary)
                        .cmuxFont(size: 12, weight: info.agent == nil ? .regular : .medium)
                        .foregroundStyle(info.agent.map { agentColor($0.state) } ?? Color.primary)
                        .lineLimit(1)
                    if let agent = info.agent {
                        Text(agent.state.label)
                            .cmuxFont(size: 9)
                            .foregroundStyle(agentColor(agent.state))
                            .lineLimit(1)
                    }
                }
                if let secondary {
                    Text(secondary)
                        .cmuxFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if info.isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .help(String(localized: "harbor.terminal.active", defaultValue: "Active"))
            }
        }
        .padding(.vertical, secondary == nil ? 3 : 2)
        .padding(.trailing, 6)
    }

    private func simpleRow(icon: String, tint: Color, title: String, detail: String?, dimmed: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: detail == nil ? 0 : 1) {
                Text(title)
                    .cmuxFont(size: 12, weight: .regular)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .cmuxFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, detail == nil ? 3 : 2)
        .padding(.trailing, 6)
    }

    private func statusColor(_ status: HarborHostSnapshot.Status) -> Color {
        if case .unreachable = status { return .orange }
        if case .loading = status { return .secondary }
        return .green
    }

    private func toolColor(_ tool: HarborTool) -> Color {
        switch tool {
        case .tmux: return .blue
        case .zellij: return .purple
        case .screen: return .teal
        case .zmx: return .orange
        case .herdr: return .pink
        case .cmuxTui: return .indigo
        }
    }

    private func agentColor(_ state: HarborAgentState) -> Color {
        switch state {
        case .blocked: return .orange
        case .working: return .green
        case .done: return .blue
        case .idle, .unknown: return .secondary
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        if !home.isEmpty, path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

@MainActor
final class HarborTreeMenuItem: NSMenuItem {
    private let actionBlock: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        actionBlock = action
        super.init(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func performAction(_ sender: Any?) { actionBlock() }
}
