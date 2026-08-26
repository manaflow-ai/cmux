import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// The Finder-like Cloud tree over the surface catalog: This Mac (local
/// workspaces → terminals; Browsers) then every machine (Workspaces → cmux-tui
/// workspace → terminals; Desktop; Ports), as an `NSOutlineView`. Rows are pure
/// display (`CloudTreeRowContentView`); the coordinator owns selection,
/// expansion, double-click, context menus, keyboard navigation, and the native
/// drag whose drop projects the row as a pane in the main view.
struct CloudTreeOutlineView: NSViewRepresentable {
    let machines: [MachineSnapshot]
    let snapshot: SurfaceCatalogSnapshot
    let localWorkspaces: [CloudTreeLocalWorkspace]
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions
    let expansionStore: CloudTreeExpansionStore
    @Environment(\.tabDragTransferRegistry) private var tabDragTransferRegistry
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore,
            tabDragTransferRegistry: { [tabDragTransferRegistry] in
                tabDragTransferRegistry ?? AppDelegate.shared?.tabDragTransferRegistry
            }
        )
    }

    func makeNSView(context: Context) -> CloudTreeContainerView {
        let container = CloudTreeContainerView(coordinator: context.coordinator)
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        return container
    }

    func updateNSView(_ container: CloudTreeContainerView, context: Context) {
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.machineActions = machineActions
        context.coordinator.nodeActions = nodeActions
        context.coordinator.apply(nodes: CloudTreeNodeBuilder.nodes(machines: machines, snapshot: snapshot, localWorkspaces: localWorkspaces))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var machineActions: MachineRowActions
        var nodeActions: CloudTreeNodeActions
        let expansionStore: CloudTreeExpansionStore
        private let tabDragTransferRegistry: @MainActor () -> TabDragTransferRegistry?
        weak var outlineView: CloudTreeNSOutlineView?
        private var nodes: [CloudTreeNode] = []
        private var signature: [String] = []
        private var selectedNodeID: String?
        private var isUpdatingProgrammatically = false
        private var activeDrag: (id: UUID, registration: TabDragTransferRegistration)?

        init(
            machineActions: MachineRowActions,
            nodeActions: CloudTreeNodeActions,
            expansionStore: CloudTreeExpansionStore,
            tabDragTransferRegistry: @escaping @MainActor () -> TabDragTransferRegistry?
        ) {
            self.machineActions = machineActions
            self.nodeActions = nodeActions
            self.expansionStore = expansionStore
            self.tabDragTransferRegistry = tabDragTransferRegistry
        }

        // MARK: Snapshot application

        /// Reloads only when the flattened tree actually changed, then restores
        /// expansion (from the store) and the selection (by node id).
        func apply(nodes: [CloudTreeNode]) {
            let nextSignature = Self.signature(of: nodes)
            guard nextSignature != signature else { return }
            self.nodes = nodes
            signature = nextSignature
            guard let outlineView else { return }
            withProgrammaticUpdate {
                outlineView.reloadData()
                restoreExpansion(in: outlineView)
                restoreSelection(in: outlineView)
            }
        }

        private static func signature(of nodes: [CloudTreeNode]) -> [String] {
            CloudTreeNodeBuilder.flattened(nodes).map { "\($0.id)|\(String(describing: $0.kind))" }
        }

        private func restoreExpansion(in outlineView: NSOutlineView) {
            var row = 0
            while row < outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? CloudTreeNode,
                   node.isExpandable,
                   expansionStore.isExpanded(node) {
                    outlineView.expandItem(node)
                }
                row += 1
            }
        }

        private func restoreSelection(in outlineView: NSOutlineView) {
            guard let selectedNodeID else { return }
            for row in 0..<outlineView.numberOfRows {
                if (outlineView.item(atRow: row) as? CloudTreeNode)?.id == selectedNodeID {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }

        private func withProgrammaticUpdate(_ body: () -> Void) {
            isUpdatingProgrammatically = true
            body()
            isUpdatingProgrammatically = false
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? CloudTreeNode else { return nodes.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? CloudTreeNode else { return nodes[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? CloudTreeNode)?.isExpandable ?? false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? CloudTreeNode else { return nil }
            let cell = (outlineView.makeView(withIdentifier: CloudTreeCellView.identifier, owner: nil) as? CloudTreeCellView)
                ?? CloudTreeCellView(frame: .zero)
            cell.configure(node: node, machineActions: machineActions)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            CloudTreeRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(CloudTreeRowGrid.rowHeight) }
            switch node.kind {
            case .machine(let machine, _):
                let hasStats = machine.stats.flatMap(CloudTreeMachineRowContent.statsLine) != nil
                return GlobalFontMagnification.scaledSize(CloudTreeRowGrid.machineRowHeight(hasStats: hasStats))
            case .localMachine:
                return GlobalFontMagnification.scaledSize(CloudTreeRowGrid.machineRowHeight(hasStats: false))
            case .workspacesGroup, .portsGroup, .browsersGroup, .workspace, .localWorkspace, .terminal, .desktop, .browser, .port, .placeholder:
                return GlobalFontMagnification.scaledSize(CloudTreeRowGrid.rowHeight)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingProgrammatically, let outlineView else { return }
            selectedNodeID = outlineView.selectedRow >= 0
                ? (outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode)?.id
                : nil
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isUpdatingProgrammatically, let node = notification.userInfo?["NSObject"] as? CloudTreeNode else { return }
            expansionStore.setExpanded(true, node: node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isUpdatingProgrammatically, let node = notification.userInfo?["NSObject"] as? CloudTreeNode else { return }
            expansionStore.setExpanded(false, node: node)
        }

        // MARK: Opening

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? CloudTreeNode else { return }
            open(node)
        }

        func openSelection() {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode else { return }
            open(node)
        }

        /// One place decides what "open" means per row. Every surface row is
        /// `SurfaceCatalog.project` (reusing an open pane); a machine row starts a
        /// plain terminal on that machine.
        func open(_ node: CloudTreeNode) {
            switch node.kind {
            case .machine(let machine, _):
                openMachine(machine)
            case .localMachine, .workspacesGroup, .portsGroup, .browsersGroup:
                toggle(node)
            case .workspace(let machine, let workspace, _):
                nodeActions.openWorkspace(machine, workspace, node.children.compactMap { $0.dragResource?.id })
            case .localWorkspace(let row):
                nodeActions.selectLocalWorkspace(row.workspaceID)
            case .terminal(let row):
                nodeActions.project(row.resource.id, .split, true)
            case .desktop(let resource), .port(let resource):
                nodeActions.project(resource.id, .split, true)
            case .browser(let row):
                nodeActions.project(row.resource.id, .split, true)
            case .placeholder(let machineID, let placeholder):
                // "Asleep — open to wake": a fresh terminal on the machine is what wakes it.
                if placeholder.style == .dimmed, let machine = machine(id: machineID) {
                    openMachine(machine)
                }
            }
        }

        private func openMachine(_ machine: MachineSnapshot) {
            if machine.freeAccess == .expired {
                machineActions.promptUpgrade()
            } else {
                nodeActions.newTerminal(.cloud(machine.id), nil)
            }
        }

        private func toggle(_ node: CloudTreeNode) {
            guard let outlineView else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }

        private func machine(id: SurfaceMachineID) -> MachineSnapshot? {
            for node in nodes {
                if case .machine(let machine, _) = node.kind, .cloud(machine.id) == id { return machine }
            }
            return nil
        }

        // MARK: Keyboard

        func moveSelection(by delta: Int) {
            guard let outlineView, outlineView.numberOfRows > 0 else { return }
            let current = outlineView.selectedRow >= 0 ? outlineView.selectedRow : (delta >= 0 ? -1 : outlineView.numberOfRows)
            let target = min(max(current + delta, 0), outlineView.numberOfRows - 1)
            outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            outlineView.scrollRowToVisible(target)
        }

        func performDisclosure(_ action: RightSidebarKeyboardNavigation.DisclosureAction) {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode else { return }
            switch action {
            case .expand:
                if node.isExpandable, !outlineView.isItemExpanded(node) {
                    outlineView.expandItem(node)
                } else if node.isExpandable {
                    moveSelection(by: 1)
                }
            case .collapse:
                if node.isExpandable, outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else if let parent = outlineView.parent(forItem: node) as? CloudTreeNode {
                    let row = outlineView.row(forItem: parent)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        outlineView.scrollRowToVisible(row)
                    }
                }
            }
        }

        func selectQuickSearchMatch(query: String) {
            guard let outlineView else { return }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? CloudTreeNode else { continue }
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
            guard row >= 0, let node = outlineView.item(atRow: row) as? CloudTreeNode else { return }
            for item in menuItems(for: node) {
                menu.addItem(item)
            }
        }

        private func menuItems(for node: CloudTreeNode) -> [NSMenuItem] {
            switch node.kind {
            case .machine(let machine, _):
                return machineMenuItems(machine)
            case .localMachine:
                return [
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(.local, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .workspacesGroup(let machine):
                return [
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(machine, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .workspace(let machine, let workspace, _):
                let terminals = node.children.compactMap { $0.dragResource?.id }
                return [
                    item(String(localized: "cloudTree.menu.newTerminalHere", defaultValue: "New Terminal Here")) { [nodeActions] in nodeActions.newTerminal(machine, workspace.id) },
                    item(String(localized: "cloudTree.menu.openAll", defaultValue: "Open All Terminals")) { [nodeActions] in
                        for terminal in terminals {
                            nodeActions.project(terminal, .split, true)
                        }
                    },
                    .separator(),
                    item(String(localized: "cloudTree.menu.copyWorkspaceID", defaultValue: "Copy Workspace ID")) { [nodeActions] in nodeActions.copyToPasteboard(workspace.id) },
                ]
            case .localWorkspace(let row):
                return [
                    item(String(localized: "cloudTree.menu.selectWorkspace", defaultValue: "Go to Workspace")) { [nodeActions] in nodeActions.selectLocalWorkspace(row.workspaceID) },
                    item(String(localized: "cloudTree.menu.newTerminalHere", defaultValue: "New Terminal Here")) { [nodeActions] in nodeActions.newTerminal(.local, nil) },
                ]
            case .terminal(let row):
                return resourceMenuItems(row.resource, isLocal: row.resource.machine.isLocal)
            case .browser(let row):
                return resourceMenuItems(row.resource, isLocal: row.resource.machine.isLocal)
            case .desktop(let resource), .port(let resource):
                return resourceMenuItems(resource, isLocal: false)
            case .browsersGroup, .portsGroup:
                return [
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .placeholder(let machineID, _):
                guard let machine = machine(id: machineID) else { return [] }
                return machineMenuItems(machine)
            }
        }

        /// The verbs every surface row shares: open (reusing an open pane), open as a
        /// tab, a second pane (cloud resources only — a local terminal has one pane),
        /// and copying the resource id agents use with `cmux vm open`.
        private func resourceMenuItems(_ resource: SurfaceResource, isLocal: Bool) -> [NSMenuItem] {
            var items: [NSMenuItem] = [
                item(String(localized: "cloudTree.menu.open", defaultValue: "Open")) { [nodeActions] in nodeActions.project(resource.id, .split, true) },
                item(String(localized: "cloudTree.menu.openInNewTab", defaultValue: "Open in New Tab")) { [nodeActions] in nodeActions.project(resource.id, .tab, true) },
            ]
            if !isLocal {
                items.append(item(String(localized: "cloudTree.menu.openInNewPane", defaultValue: "Open in New Pane")) { [nodeActions] in nodeActions.project(resource.id, .split, false) })
            }
            items.append(.separator())
            if let port = resource.port, resource.kind == .browser {
                items.append(item(String(localized: "cloudTree.menu.copyPort", defaultValue: "Copy Port")) { [nodeActions] in nodeActions.copyToPasteboard(String(port)) })
            }
            items.append(item(String(localized: "cloudTree.menu.copySurfaceID", defaultValue: "Copy Surface ID")) { [nodeActions] in nodeActions.copyToPasteboard(resource.id.rawValue) })
            return items
        }

        private func machineMenuItems(_ machine: MachineSnapshot) -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            let actions = machineActions
            let nodeActions = nodeActions
            let id = machine.id
            if machine.freeAccess == .expired {
                items.append(item(String(localized: "machines.menu.upgradeToReconnect", defaultValue: "Upgrade to Reconnect\u{2026}")) { actions.promptUpgrade() })
            } else {
                items.append(item(String(localized: "machines.menu.openShell", defaultValue: "Open Shell")) { nodeActions.newTerminal(.cloud(id), nil) })
                if machine.isDesktop {
                    items.append(item(String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) {
                        nodeActions.project(SurfaceResourceID(machine: .cloud(id), kind: .screen, key: "display:1"), .split, true)
                    })
                }
                items.append(item(String(localized: "cloudTree.menu.openFullClient", defaultValue: "Open Full cmux-tui Client")) { actions.runCommand(id, ["vm", "tui"]) })
            }
            items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
            items.append(.separator())
            items.append(item(String(localized: "machines.menu.rename", defaultValue: "Rename\u{2026}")) { actions.promptRename(id, machine.label) })
            items.append(item(String(localized: "machines.menu.status", defaultValue: "Status")) { actions.runCommand(id, ["vm", "status"]) })
            items.append(item(String(localized: "machines.menu.checkpoint", defaultValue: "Checkpoint")) { actions.runCommand(id, ["vm", "snapshot"]) })
            items.append(item(String(localized: "machines.menu.fork", defaultValue: "Fork")) { actions.runCommand(id, ["vm", "fork"]) })
            items.append(.separator())
            items.append(item(String(localized: "machines.menu.delete", defaultValue: "Delete…")) { actions.confirmDelete(id) })
            return items
        }

        private func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = CloudTreeMenuItem(title: title, action: action)
            item.target = item
            return item
        }

        // MARK: Drag source

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? CloudTreeNode, let resource = node.dragResource,
                  let transferRegistry = tabDragTransferRegistry() else { return nil }
            let dragID = SurfaceResourceDragRegistry.shared.register(resource.id)
            guard let registration = SurfaceResourceDragPayload(resource: resource, dragID: dragID)
                .register(with: transferRegistry) else {
                SurfaceResourceDragRegistry.shared.discard(id: dragID)
                return nil
            }
            activeDrag = (dragID, registration)
#if DEBUG
            cmuxDebugLog("surfaces.drag.begin drag=\(dragID.uuidString.prefix(5)) resource=\(resource.id)")
#endif
            return registration.pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let activeDrag else { return }
#if DEBUG
            cmuxDebugLog("surfaces.drag.end drag=\(activeDrag.id.uuidString.prefix(5)) operation=\(operation.rawValue)")
#endif
            tabDragTransferRegistry()?.end(activeDrag.registration)
            SurfaceResourceDragRegistry.shared.discard(id: activeDrag.id)
            self.activeDrag = nil
        }
    }
}

/// Menu item carrying its own closure; the outline's context menu is rebuilt
/// per click from the clicked node, so items never outlive their target.
final class CloudTreeMenuItem: NSMenuItem {
    private let performAction: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        performAction = action
        super.init(title: title, action: #selector(perform(_:)), keyEquivalent: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc @MainActor private func perform(_ sender: Any?) {
        performAction()
    }
}

/// Scroll view + outline host for the Cloud tree.
final class CloudTreeContainerView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = CloudTreeNSOutlineView()

    init(coordinator: CloudTreeOutlineView.Coordinator) {
        super.init(frame: .zero)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        // One 16pt slot per level: the disclosure chevron lives in the last slot
        // before a row's content, and leaves keep the slot so glyphs form a column.
        outlineView.indentationPerLevel = CloudTreeRowGrid.disclosureSlot
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.setAccessibilityIdentifier("CloudMachinesTree")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(CloudTreeOutlineView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        outlineView.onMoveSelection = { [weak coordinator] delta in coordinator?.moveSelection(by: delta) }
        outlineView.onDisclosure = { [weak coordinator] action in coordinator?.performDisclosure(action) }
        outlineView.onQuickSearch = { [weak coordinator] query in coordinator?.selectQuickSearchMatch(query: query) }
        outlineView.onDidBecomeFirstResponder = { [weak self] in
            guard let self, let window = self.window else { return }
            AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .machines, in: window)
        }
        coordinator.outlineView = outlineView

        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
