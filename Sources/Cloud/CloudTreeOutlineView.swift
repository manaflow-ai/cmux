import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// The Finder-like Cloud tree over the surface catalog: This Mac (local
/// workspaces → terminals; Browsers) then every machine (Workspaces → cmux-tui
/// workspace → terminals; Desktop; Ports), as an `NSOutlineView`. Rows are pure
/// display (`CloudTreeRowContentView`); the coordinator owns selection,
/// expansion, clicks, context menus, keyboard navigation, and the native
/// drag whose drop projects the row as a pane in the main view.
struct CloudTreeOutlineView: NSViewRepresentable {
    let machines: [MachineSnapshot]
    /// Creates still running or failed, shown as pending rows above the fleet.
    var pendingCreates: [MachineCreateOperation] = []
    let snapshot: SurfaceCatalogSnapshot
    let localWorkspaces: [CloudTreeLocalWorkspace]
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions
    let expansionStore: CloudTreeExpansionStore
    /// The visual preset the rows render in (the debug gallery pins one per
    /// column; the live panel passes the stored choice).
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    /// Fires when a row drag starts (true) and ends (false); the panel freezes catalog
    /// re-reads while a drag is in flight.
    var onDragStateChange: @MainActor (Bool) -> Void = { _ in }
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
        context.coordinator.onDragStateChange = onDragStateChange
        context.coordinator.apply(style: style)
        context.coordinator.apply(nodes: CloudTreeNodeBuilder.nodes(
            machines: machines,
            pendingCreates: pendingCreates,
            snapshot: snapshot,
            localWorkspaces: localWorkspaces
        ))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var machineActions: MachineRowActions
        var nodeActions: CloudTreeNodeActions
        let expansionStore: CloudTreeExpansionStore
        private(set) var style: CloudTreeStyle = CloudTreeStyleStore.current
        private let tabDragTransferRegistry: @MainActor () -> TabDragTransferRegistry?
        weak var outlineView: CloudTreeNSOutlineView?
        private var nodes: [CloudTreeNode] = []
        private var structureSignature: [String] = []
        private var contentSignature: [String] = []
        private var selectedNodeID: String?
        private var isUpdatingProgrammatically = false
        private var activeDrag: ActiveDrag?
        // NSDraggingItem retains the writer for the live native session. A weak
        // coordinator edge prevents a retained writer/container cycle.
        private weak var activeDragWriter: CloudTreeSurfaceDragPasteboardWriter?
        private var activeDragSequenceNumber: Int?
        private var activeDragSession: NSDraggingSession?
        private weak var activeDragSourceView: CloudTreeNSOutlineView?
        private var supersededDragSession: NSDraggingSession?
        private var supersededDragSequenceNumber: Int?
        private var pendingDrags: [UUID: PendingDrag] = [:]
        private weak var latestPendingDragWriter: CloudTreeSurfaceDragPasteboardWriter?
        private lazy var dragWriterOwnership = ProvisionalDragWriterOwnership { [weak self] tokenID in
            self?.pendingDragWriterDidDeallocate(tokenID: tokenID)
        }
        /// A drag session owns the outline until it ends: no reloads, no in-place
        /// updates. The latest tree handed in meanwhile is applied once at drag end.
        private(set) var isDragging = false
        private var deferredNodes: [CloudTreeNode]?
        var onDragStateChange: @MainActor (Bool) -> Void = { _ in }

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

        private func discardPendingDrag(_ pending: PendingDrag) {
            pending.transferRegistry.end(pending.registration)
            SurfaceResourceDragRegistry.shared.discard(id: pending.dragID)
        }

        private func discardAllPendingDrags(
            preserving preservedWriter: CloudTreeSurfaceDragPasteboardWriter? = nil
        ) {
            let pending = pendingDrags
            pendingDrags.removeAll(keepingCapacity: false)
            latestPendingDragWriter = nil
            for (tokenID, pending) in pending {
                if pending.writer === preservedWriter {
                    pendingDrags[tokenID] = pending
                    latestPendingDragWriter = preservedWriter
                    continue
                }
                dragWriterOwnership.remove(id: tokenID)
                pending.writer?.releaseSourceGraph()
                discardPendingDrag(pending)
            }
        }

        private func pendingDragWriterDidDeallocate(tokenID: UUID) {
            guard let pending = pendingDrags.removeValue(forKey: tokenID) else { return }
            if latestPendingDragWriter?.provisionalToken.id == tokenID {
                latestPendingDragWriter = nil
            }
            discardPendingDrag(pending)
            guard !dragWriterOwnership.hasPendingTokens else { return }
            // No native session was promoted for this token. The provisional
            // writer's deallocation is therefore the exact boundary at which
            // its capability and routing registration can be discarded.
            if activeDrag == nil, activeDragSession == nil {
                outlineView?.activeNativeDragCoordinator = nil
                outlineView?.activeNativeDragSession = nil
                setDragging(false)
            }
        }

        private func reclaimSupersededNativeDragIfNeeded() {
            guard activeDrag != nil || isDragging else { return }
            supersededDragSession = activeDragSession ?? outlineView?.activeNativeDragSession
            supersededDragSequenceNumber = activeDragSequenceNumber
            if let activeDrag {
                self.activeDrag = nil
                activeDrag.transferRegistry.end(activeDrag.registration)
                SurfaceResourceDragRegistry.shared.discard(id: activeDrag.id)
            }
            activeDragWriter?.releaseSourceGraph()
            activeDragWriter = nil
            activeDragSession = nil
            activeDragSequenceNumber = nil
            if let sourceView = activeDragSourceView {
                sourceView.activeNativeDragCoordinator = nil
                sourceView.activeNativeDragSession = nil
            } else if let outlineView,
                      (outlineView.activeNativeDragSession == nil
                           || outlineView.activeNativeDragCoordinator === self) {
                outlineView.activeNativeDragCoordinator = nil
                outlineView.activeNativeDragSession = nil
            }
            activeDragSourceView = nil
        }

        /// Reclaims a native Cloud drag after AppKit has crossed a new pointer
        /// boundary without delivering the older source's `endedAt` callback.
        /// The boundary is safe because AppKit does not dispatch a new
        /// `mouseDown` while the older native drag loop is still running.
        func prepareForNativeDragBoundary(on sourceView: CloudTreeNSOutlineView) {
            if let activeDragSourceView, activeDragSourceView !== sourceView,
               outlineView !== sourceView {
                // A stale callback from an older outline must not retire the
                // current source. A rebuilt current outline, however, is the
                // authoritative pointer boundary for the retained old source.
                return
            }
            if let activeDragSession = activeDragSession ?? sourceView.activeNativeDragSession {
                supersededDragSession = activeDragSession
            }
            if let activeDragSequenceNumber = activeDragSequenceNumber
                ?? sourceView.activeNativeDragSession?.draggingSequenceNumber {
                supersededDragSequenceNumber = activeDragSequenceNumber
            }
            if let activeDrag {
                self.activeDrag = nil
                activeDrag.transferRegistry.end(activeDrag.registration)
                SurfaceResourceDragRegistry.shared.discard(id: activeDrag.id)
            }
            activeDragWriter?.releaseSourceGraph()
            activeDragWriter = nil
            discardAllPendingDrags()
            activeDragSession = nil
            activeDragSequenceNumber = nil
            activeDragSourceView?.activeNativeDragCoordinator = nil
            activeDragSourceView?.activeNativeDragSession = nil
            sourceView.activeNativeDragCoordinator = nil
            sourceView.activeNativeDragSession = nil
            activeDragSourceView = nil
            setDragging(false)
        }

        // MARK: Snapshot application

        /// Three outcomes, cheapest first: nothing changed → no work; only row contents
        /// changed (titles, cwd, open markers, stats) → the existing node objects adopt the
        /// new values and the visible rows re-render in place, keeping expansion and the
        /// selection; the structure changed (rows added/removed/reordered/re-kinded) →
        /// `reloadData` plus expansion/selection restore. During a drag everything is
        /// deferred until the session ends.
        /// Switch the visual preset: every row's height, indent and content
        /// change, so this is always a full reload (cheap — the tree is small).
        func apply(style: CloudTreeStyle) {
            guard style != self.style else { return }
            self.style = style
            guard let outlineView else { return }
            outlineView.treeStyle = style
            outlineView.indentationPerLevel = style.indentPerLevel
            withProgrammaticUpdate {
                outlineView.reloadData()
                restoreExpansion(in: outlineView)
                restoreSelection(in: outlineView)
            }
        }

        func apply(nodes: [CloudTreeNode]) {
            if isDragging {
                deferredNodes = nodes
                return
            }
            let nextStructure = CloudTreeNodeBuilder.structureSignature(nodes)
            let nextContent = CloudTreeNodeBuilder.contentSignature(nodes)
            guard nextStructure != structureSignature || nextContent != contentSignature else { return }
            contentSignature = nextContent
            if nextStructure == structureSignature, !self.nodes.isEmpty {
                for (existing, replacement) in zip(self.nodes, nodes) {
                    existing.adopt(from: replacement)
                }
                guard let outlineView, outlineView.numberOfRows > 0 else { return }
                withProgrammaticUpdate {
                    outlineView.reloadData(
                        forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
                return
            }
            self.nodes = nodes
            structureSignature = nextStructure
            guard let outlineView else { return }
            withProgrammaticUpdate {
                outlineView.reloadData()
                restoreExpansion(in: outlineView)
                restoreSelection(in: outlineView)
            }
        }

        private func setDragging(_ dragging: Bool) {
            guard isDragging != dragging else { return }
            isDragging = dragging
            onDragStateChange(dragging)
            if !dragging, let deferred = deferredNodes {
                deferredNodes = nil
                apply(nodes: deferred)
            }
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
            cell.configure(node: node, machineActions: machineActions, nodeActions: nodeActions, style: style)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            CloudTreeRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
            switch node.kind {
            case .machine(let machine, _):
                let hasStats = machine.stats.flatMap(CloudTreeMachineRowContent.statsLine) != nil
                let hasUsage = machine.usage.flatMap(CloudTreeMachineRowContent.usageLine) != nil
                return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: hasStats, hasUsage: hasUsage))
            case .localMachine, .pendingMachine:
                return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
            case .terminalsPool, .displaysPool, .workspacesGroup, .portsGroup, .browsersGroup, .workspace, .localWorkspace, .terminal, .display, .browser, .port, .placeholder:
                return GlobalFontMagnification.scaledSize(style.rowHeight)
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

        /// One click means open (D9): a click on any row carries the intent to
        /// open it — workspace rows included (austin, 2026-08-31: they used to
        /// toggle on the first click and open only on double-click, which made a
        /// double-click flip the container's expansion while opening). Extra
        /// clicks of a double- or triple-click are ignored, so a habitual
        /// double-click acts exactly once and never spawns twice. Expansion is
        /// the chevron's job (and h/l on the keyboard), never a click side effect
        /// on workspace rows; machine and group rows still toggle because toggle
        /// IS their open verb.
        @objc func handleSingleClick(_ sender: Any?) {
            guard let outlineView, NSApp.currentEvent.map({ $0.clickCount <= 1 }) ?? true else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? CloudTreeNode else { return }
#if DEBUG
            cmuxDebugLog("cloudTree.click row=\(row) kind=\(node.structureTag) clicks=\(NSApp.currentEvent?.clickCount ?? -1)")
#endif
            open(node)
        }

        func openSelection() {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode else { return }
            open(node)
        }

        /// One place decides what "open" means per row. Every surface row is
        /// `SurfaceCatalog.project` (focusing an open pane first); machine and
        /// group rows toggle. Creation is never an open side effect: the hover
        /// "+" and the context menu own it (an expired machine still prompts,
        /// and the asleep placeholder still wakes, because those rows advertise
        /// exactly that).
        func open(_ node: CloudTreeNode) {
            switch node.kind {
            case .machine(let machine, _):
                if machine.freeAccess == .expired {
                    machineActions.promptUpgrade()
                } else {
                    toggle(node)
                }
            case .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .portsGroup, .browsersGroup:
                toggle(node)
            case .pendingMachine(let operation):
                // Nothing to open yet. A failed create's click shows why (the
                // CLI transcript); a running one has nothing to say beyond its row.
                if !operation.isRunning {
                    machineActions.create.showFailure(operation.id)
                }
            case .workspace(let machine, let workspace, _, let openIn):
                // Open-or-focus (D13). Already showing in a local workspace -> go there
                // instead of opening a second copy; a
                // stray pane showing one of its terminals -> focus that pane.
                // Otherwise the remote workspace opens as its OWN local workspace —
                // remote and local workspaces never intermingle. D9: open never
                // creates — an empty workspace row opens nothing here; its "+" and
                // menu own creation.
                if let openIn {
                    nodeActions.selectLocalWorkspace(openIn)
                } else if let shown = node.children.first(where: { child in
                    if case .terminal(let row) = child.kind { return row.isOpen }
                    return false
                }), case .terminal(let openRow) = shown.kind {
                    // A terminal opens as a tab, not a new column: it joins the
                    // existing layout instead of widening it every time.
                    nodeActions.project(openRow.resource.id, .tab, true)
                } else if let group = node.dragGroup, !group.isEmpty {
                    nodeActions.openGroupAsWorkspace(machine, group, workspace.id)
                }
            case .localWorkspace(let row):
                nodeActions.selectLocalWorkspace(row.workspaceID)
            case .terminal(let row):
                // A terminal opens as a tab, not a new column: it joins the
                // existing layout instead of widening it every time.
                nodeActions.project(row.resource.id, .tab, true)
            case .display(let resource, let openIn):
                // A workspace's Desktop row opens INSIDE the local workspace showing
                // that remote workspace — never a jump to a VNC pane in a different
                // workspace. Pool rows (openIn == nil) keep the global open-or-focus.
                if let openIn {
                    nodeActions.projectInLocalWorkspace(resource.id, openIn)
                } else {
                    nodeActions.project(resource.id, .split, true)
                }
            case .port(let resource, _):
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
#if DEBUG
            cmuxDebugLog("cloudTree.toggle kind=\(node.structureTag) expanded=\(outlineView.isItemExpanded(node))")
#endif
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

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let outlineView else { return nil }
            let resolvedRow = row >= 0 ? row : outlineView.selectedRow
            guard resolvedRow >= 0, let node = outlineView.item(atRow: resolvedRow) as? CloudTreeNode else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in menuItems(for: node) {
                menu.addItem(item)
            }
            #if DEBUG
            cmuxDebugLog("cloudTree.menu.build row=\(resolvedRow) items=\(menu.items.count)")
            #endif
            return menu.items.isEmpty ? nil : menu
        }

        private func menuItems(for node: CloudTreeNode) -> [NSMenuItem] {
            switch node.kind {
            case .machine(let machine, _):
                return machineMenuItems(machine)
            case .pendingMachine(let operation):
                return pendingMachineMenuItems(operation)
            case .localMachine:
                return [
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(.local, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .terminalsPool(let machine, _):
                return [
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(machine, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .displaysPool(let machine, _):
                return [
                    item(String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) { [nodeActions] in
                        nodeActions.project(SurfaceResourceID(machine: machine, kind: .display, key: SurfaceResourceID.desktopDisplayKey), .split, true)
                    },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .workspacesGroup(let machine):
                return [
                    item(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { [nodeActions] in nodeActions.newWorkspace(machine) },
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(machine, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .workspace(let machine, let workspace, _, let openIn):
                // One open verb, THE SAME PATH as a click and Return (`open`):
                // jump to the local workspace already showing it (the verb says so),
                // focus a stray pane showing one of its terminals, refuse an empty
                // group, else open as an own local workspace (remote and local never
                // intermingle, D13).
                let openTitle = openIn == nil
                    ? String(localized: "cloudTree.menu.openWorkspace", defaultValue: "Open Workspace")
                    : String(localized: "cloudTree.menu.selectWorkspace", defaultValue: "Go to Workspace")
                return [
                    item(openTitle) { [weak self] in self?.open(node) },
                    item(String(localized: "cloudTree.menu.newTerminalHere", defaultValue: "New Terminal Here")) { [nodeActions] in nodeActions.newTerminal(machine, workspace.id) },
                    .separator(),
                    item(String(localized: "cloudTree.menu.renameWorkspace", defaultValue: "Rename\u{2026}")) { [nodeActions] in nodeActions.renameWorkspace(machine, workspace) },
                    item(String(localized: "cloudTree.menu.copyWorkspaceID", defaultValue: "Copy Workspace ID")) { [nodeActions] in nodeActions.copyToPasteboard(workspace.id) },
                    .separator(),
                    // One close verb, same path as the row's hover ×: the workspace and
                    // its terminals go together (nothing lingers as a pool row).
                    item(String(localized: "cloudTree.menu.closeWorkspace", defaultValue: "Close Workspace\u{2026}")) { [nodeActions] in nodeActions.closeWorkspace(machine, workspace) },
                ]
            case .localWorkspace(let row):
                var items = [
                    item(String(localized: "cloudTree.menu.selectWorkspace", defaultValue: "Go to Workspace")) { [nodeActions] in nodeActions.selectLocalWorkspace(row.workspaceID) },
                    item(String(localized: "cloudTree.menu.newTerminalHere", defaultValue: "New Terminal Here")) { [nodeActions] in nodeActions.newTerminal(.local, nil) },
                ]
                if let group = node.dragGroup {
                    items.append(item(String(localized: "cloudTree.menu.openAllHere", defaultValue: "Open All Here")) { [nodeActions] in nodeActions.openGroup(.local, group, .split, nil) })
                }
                return items
            case .terminal(let row):
                var items = resourceMenuItems(row.resource, isLocal: row.resource.machine.isLocal)
                if !row.resource.machine.isLocal {
                    items.append(.separator())
                    items.append(item(String(localized: "cloudTree.menu.killTerminal", defaultValue: "Kill Terminal\u{2026}")) { [nodeActions] in nodeActions.closeTerminal(row.resource.id) })
                }
                return items
            case .browser(let row):
                return resourceMenuItems(row.resource, isLocal: row.resource.machine.isLocal)
            case .display(let resource, let openIn):
                return resourceMenuItems(resource, isLocal: false, openInLocalWorkspace: openIn)
            case .port(let resource, let url):
                return resourceMenuItems(resource, isLocal: false, portURL: url)
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
        private func resourceMenuItems(
            _ resource: SurfaceResource,
            isLocal: Bool,
            openInLocalWorkspace: UUID? = nil,
            portURL: String? = nil
        ) -> [NSMenuItem] {
            var items: [NSMenuItem] = [
                item(String(localized: "cloudTree.menu.open", defaultValue: "Open")) { [nodeActions] in
                    // Same scope rule as the row's open verb (one shared path).
                    if let openInLocalWorkspace {
                        nodeActions.projectInLocalWorkspace(resource.id, openInLocalWorkspace)
                    } else {
                        nodeActions.project(resource.id, .split, true)
                    }
                },
                item(String(localized: "cloudTree.menu.openInNewTab", defaultValue: "Open in New Tab")) { [nodeActions] in nodeActions.project(resource.id, .tab, true) },
            ]
            if !isLocal {
                items.append(item(String(localized: "cloudTree.menu.openInNewPane", defaultValue: "Open in New Pane")) { [nodeActions] in nodeActions.project(resource.id, .split, false) })
            }
            items.append(.separator())
            if let portURL {
                items.append(item(String(localized: "cloudTree.menu.copyLink", defaultValue: "Copy Link")) { [nodeActions] in nodeActions.copyToPasteboard(portURL) })
            } else if let port = resource.port, resource.kind == .browser {
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
                items.append(item(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { nodeActions.newWorkspace(.cloud(id)) })
                if machine.isDesktop {
                    items.append(item(String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) {
                        nodeActions.project(SurfaceResourceID(machine: .cloud(id), kind: .display, key: SurfaceResourceID.desktopDisplayKey), .split, true)
                    })
                }
                items.append(item(String(localized: "cloudTree.menu.openFullClient", defaultValue: "Open Full cmux-tui Client")) { actions.runCommand(id, ["vm", "tui"]) })
            }
            items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
            items.append(.separator())
            items.append(item(String(localized: "machines.menu.rename", defaultValue: "Rename\u{2026}")) { actions.promptRename(id, machine.label) })
            if let address = machine.privateAddress {
                items.append(item(String(localized: "machines.menu.copyIPAddress", defaultValue: "Copy IP Address")) { [nodeActions] in nodeActions.copyToPasteboard(address) })
            }
            items.append(item(String(localized: "machines.menu.status", defaultValue: "Status")) { actions.runCommand(id, ["vm", "status"]) })
            // Only verbs this provider can honor: a Checkpoint that answers 502 is not a verb.
            if machine.capabilities.snapshot {
                items.append(item(String(localized: "machines.menu.checkpoint", defaultValue: "Checkpoint")) { actions.runCommand(id, ["vm", "snapshot"]) })
            }
            if machine.capabilities.fork {
                items.append(item(String(localized: "machines.menu.fork", defaultValue: "Fork")) { actions.runCommand(id, ["vm", "fork"]) })
            }
            items.append(.separator())
            items.append(item(String(localized: "machines.menu.delete", defaultValue: "Delete…")) { actions.confirmDelete(id) })
            return items
        }

        /// A running create offers nothing but Refresh; a failed one offers the
        /// same verbs as its hover buttons plus the transcript.
        private func pendingMachineMenuItems(_ operation: MachineCreateOperation) -> [NSMenuItem] {
            let create = machineActions.create
            let nodeActions = nodeActions
            let id = operation.id
            var items: [NSMenuItem] = []
            if !operation.isRunning {
                items.append(item(String(localized: "machines.pending.retry", defaultValue: "Retry Create")) { create.retry(id) })
                items.append(item(String(localized: "machines.pending.showError", defaultValue: "Show Error\u{2026}")) { create.showFailure(id) })
                items.append(item(String(localized: "machines.pending.copyError", defaultValue: "Copy Error")) { create.copyFailure(id) })
                items.append(.separator())
            }
            items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
            if !operation.isRunning {
                items.append(.separator())
                items.append(item(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss")) { create.dismiss(id) })
            }
            return items
        }

        private func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = CloudTreeMenuItem(title: title, action: action)
            item.target = item
            return item
        }

        // MARK: Drag source

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // Only terminals and displays leave the tree by drag (lawrence,
            // 2026-08-27). Workspaces are containers (their drag becomes the D2
            // mirror later); browsers and ports open in place.
            guard let node = item as? CloudTreeNode, node.isDragSource,
                  let group = node.dragGroup, let lead = group.resources.first,
                  let transferRegistry = tabDragTransferRegistry() else { return nil }
            // Do not mutate the outline while AppKit is asking for this
            // writer. The `willBeginAt` callback below is the next native
            // boundary and performs any superseded-source reclamation after
            // this data-source callback has returned.
            let dragID = SurfaceResourceDragRegistry.shared.register(group)
            guard let registration = SurfaceResourceDragPayload(group: group, leadKind: lead.kind, dragID: dragID)
                .register(with: transferRegistry) else {
                SurfaceResourceDragRegistry.shared.discard(id: dragID)
                return nil
            }
            let writer = CloudTreeSurfaceDragPasteboardWriter(
                dragID: dragID,
                registration: registration,
                sourceView: outlineView,
                coordinator: self,
                provisionalToken: dragWriterOwnership.makeToken()
            )
            pendingDrags[writer.provisionalToken.id] = PendingDrag(
                dragID: dragID,
                registration: registration,
                transferRegistry: transferRegistry,
                sourceView: outlineView,
                writer: writer
            )
            latestPendingDragWriter = writer
#if DEBUG
            cmuxDebugLog("surfaces.drag.begin drag=\(dragID.uuidString.prefix(5)) group=\(group.title) count=\(group.resources.count) lead=\(lead)")
#endif
            return writer
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            _ = screenPoint
            _ = draggedItems
            if activeDrag != nil || isDragging {
                if let activeSession = activeDragSession,
                   activeSession === session {
                    // AppKit may repeat begin while it hands the same native
                    // session across a reconstructed outline. The first
                    // promotion owns the registration and source generation.
                    return
                }
                // A newer begin is a native boundary even when the older
                // outline omitted `endedAt`; any distinct begin is an
                // authoritative boundary even when the OS reuses a sequence
                // number. Retire the older registration before promotion.
                reclaimSupersededNativeDragIfNeeded()
            }
            let pendingWriter: CloudTreeSurfaceDragPasteboardWriter? = {
                if let writer = latestPendingDragWriter,
                   let sourceView = writer.sourceViewForDrag,
                   sourceView === outlineView {
                    return writer
                }
                return pendingDrags.first { $0.value.sourceView === outlineView }?.value.writer
            }()
            let pendingToken = pendingWriter?.provisionalToken.id
                ?? pendingDrags.first { $0.value.sourceView === outlineView }?.key
            guard let pendingToken,
                  let pending = pendingDrags.removeValue(forKey: pendingToken) else {
                // Even if a bookkeeping token was released before this
                // callback, AppKit has already started a native drag. Freeze
                // the outline for its terminal callback so catalog updates
                // cannot reload rows under the live session.
                if let outlineView = outlineView as? CloudTreeNSOutlineView {
                    outlineView.activeNativeDragCoordinator = self
                    outlineView.activeNativeDragSession = session
                    activeDragSourceView = outlineView
                }
                activeDragSession = session
                activeDragSequenceNumber = session.draggingSequenceNumber
                setDragging(true)
                return
            }
            dragWriterOwnership.remove(id: pendingToken)
            // Cloud rows are single-selection sources, so any additional
            // provisional writers belong to the same pre-session query and
            // must be revoked rather than left in the capability registries.
            discardAllPendingDrags(preserving: pendingWriter)
            // The promoted registration was removed with the pending map;
            // retain it as the active session's sole capability.
            activeDrag = ActiveDrag(
                id: pending.dragID,
                registration: pending.registration,
                transferRegistry: pending.transferRegistry
            )
            activeDragWriter = pendingWriter
            activeDragSession = session
            activeDragSourceView = outlineView as? CloudTreeNSOutlineView
            supersededDragSession = nil
            supersededDragSequenceNumber = nil
            if let outlineView = outlineView as? CloudTreeNSOutlineView {
                outlineView.activeNativeDragCoordinator = self
                outlineView.activeNativeDragSession = session
            }
            activeDragSequenceNumber = session.draggingSequenceNumber
            setDragging(true)
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let supersededDragSession,
               supersededDragSession === session {
                // This is the terminal callback for a source already retired
                // at a newer native boundary; it must not touch a replacement
                // writer that is still waiting for willBeginAt.
                self.supersededDragSession = nil
                supersededDragSequenceNumber = nil
                return
            }
            if activeDrag == nil,
               activeDragSequenceNumber == nil,
               let supersededDragSequenceNumber,
               session.draggingSequenceNumber == supersededDragSequenceNumber {
                self.supersededDragSequenceNumber = nil
                return
            }
            if let activeSession = activeDragSession,
               activeSession !== session {
                // A late callback from an older native object must not clear
                // the owner or registration for a newer session, even if the
                // OS reuses a sequence number.
                return
            }
            if let activeDragSequenceNumber,
               session.draggingSequenceNumber != activeDragSequenceNumber {
                // A late callback from an older outline source must not revoke
                // the registration for a newer surface drag.
                return
            }
            defer {
                if let outlineView = outlineView as? CloudTreeNSOutlineView,
                   outlineView.activeNativeDragSession === session {
                    outlineView.activeNativeDragCoordinator = nil
                    outlineView.activeNativeDragSession = nil
                }
                if activeDragSourceView?.activeNativeDragSession === session {
                    activeDragSourceView?.activeNativeDragCoordinator = nil
                    activeDragSourceView?.activeNativeDragSession = nil
                }
                activeDragSequenceNumber = nil
                activeDragSession = nil
                activeDragWriter?.releaseSourceGraph()
                activeDragWriter = nil
                activeDragSourceView = nil
                setDragging(false)
            }
            guard let activeDrag else {
                // This callback is attributable only when the coordinator
                // recorded the same native session (the no-registration path
                // still freezes the outline and clears its local owner in the
                // defer above). An unknown late callback must not revoke a
                // newer writer that is still waiting for its own willBeginAt.
                return
            }
#if DEBUG
            cmuxDebugLog("surfaces.drag.end drag=\(activeDrag.id.uuidString.prefix(5)) operation=\(operation.rawValue)")
#endif
            // The registration is paired with the exact source that promoted
            // this session; do not consult a potentially rebuilt environment.
            activeDrag.transferRegistry.end(activeDrag.registration)
            SurfaceResourceDragRegistry.shared.discard(id: activeDrag.id)
            self.activeDrag = nil
        }
    }
}

/// Menu item carrying its own closure; the outline's context menu is rebuilt
/// per click from the clicked node, so items never outlive their target.
final class CloudTreeMenuItem: NSMenuItem {
    private let runAction: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        runAction = action
        // The selector is deliberately NOT named `perform(_:)`: that compiles
        // to `perform:`, which collides with NSObject's perform machinery and
        // the click never reached the method. `execute` mirrors the sidebar's
        // SidebarRowMenuActionItem, the proven shape.
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc @MainActor private func execute() {
        #if DEBUG
        cmuxDebugLog("cloudTree.menu.execute title=\(title)")
        #endif
        runAction()
    }
}

/// Scroll view + outline host for the Cloud tree.
final class CloudTreeContainerView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = CloudTreeNSOutlineView()
    private let coordinator: CloudTreeOutlineView.Coordinator

    init(coordinator: CloudTreeOutlineView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        // One slot per level (style-sized): the disclosure chevron lives in the
        // last slot before a row's content, and leaves keep the slot so glyphs
        // form a column. `apply(style:)` keeps this in step with the preset.
        outlineView.indentationPerLevel = CloudTreeStyleStore.current.indentPerLevel
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
        // The one column's width is derived from the live bounds on EVERY layout
        // pass (see `layout()`), never left to resize notifications: a width set
        // only during live-resize events is exactly the "row content is wrong
        // until I drag the divider" class of bug.
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        // D9: one click opens, on every row. The single-click handler ignores
        // the extra clicks of a double-click, so a habitual double-click acts
        // once and never opens twice. No doubleAction: nothing is double-click
        // only anymore.
        outlineView.action = #selector(CloudTreeOutlineView.Coordinator.handleSingleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        outlineView.onMoveSelection = { [weak coordinator] delta in coordinator?.moveSelection(by: delta) }
        outlineView.onDisclosure = { [weak coordinator] action in coordinator?.performDisclosure(action) }
        outlineView.onQuickSearch = { [weak coordinator] query in coordinator?.selectQuickSearchMatch(query: query) }
        outlineView.onNativeDragPointerBoundary = { [weak coordinator, weak outlineView] in
            guard let outlineView else { return }
            coordinator?.prepareForNativeDragBoundary(on: outlineView)
        }
        outlineView.onDidBecomeFirstResponder = { [weak self] in
            guard let self, let window = self.window else { return }
            AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .machines, in: window)
        }
        coordinator.outlineView = outlineView

        outlineView.contextMenuBuilder = { [weak coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }

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

    /// Width is a pure function of the current bounds, recomputed on every layout
    /// pass. Rows are correct on first display, on sidebar show, and on any
    /// programmatic resize — not only after a live divider drag.
    override func layout() {
        super.layout()
        outlineView.sizeLastColumnToFit()
    }
}
