import CmuxCloud
import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSurfaceCatalogModel
import SwiftUI
/// The Cloud catalog outline: local workspaces, then machine workspaces and resources. Rows are pure
/// display (`CloudTreeRowContentView`); the coordinator owns selection,
/// expansion, clicks, context menus, keyboard navigation, and the native
/// drag whose drop projects the row as a pane in the main view.
struct CloudTreeOutlineView: NSViewRepresentable {
    let machines: [MachineSnapshot]
    /// Cloud machines whose delete is in flight; their rows keep expansion and selection for a rollback.
    var pendingMachineDeletions: Set<String> = []
    /// Creates still running or failed, shown as pending rows above the fleet.
    var pendingCreates: [MachineCreateOperation] = []
    var adoptedOperationIDs: [String: UUID] = [:]
    let snapshot: SurfaceCatalogSnapshot
    let localWorkspaces: [CloudTreeLocalWorkspace]
    /// Machine id to terminal ids with a notification this Mac has not read.
    var unreadTerminalIDs: [String: Set<String>] = [:]
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions
    let expansionStore: CloudTreeExpansionStore
    var organizationStore: CloudSidebarOrganizationStore? = nil
    var organizationState = CloudSidebarOrganizationState()
    /// The visual preset the rows render in (the debug gallery pins one per
    /// column; the live panel passes the stored choice).
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    /// Fires when a row drag starts (true) and ends (false); the panel freezes catalog
    /// re-reads while a drag is in flight.
    var onDragStateChange: @MainActor (Bool) -> Void = { _ in }
    var source: CloudTreeMachineSource = .cloud
    var devicesSection: CloudTreeDevicesSection = .init()
    var showsCloudVPNWarning = false
    /// The Cloud Machines header's New Machine "+" and its plan count (nil until the plan loads).
    var canCreateCloudMachine: Bool = false
    var cloudMachinesUsage: CloudMachinesUsage? = nil
    var reveal: CloudTreeRevealRequest? = nil
    var creationReveal: CloudWorkspaceCreationReveal? = nil
    var nodeBuilder: ((CloudTreeBuildInputs) -> [CloudTreeNode])? = nil
    @Environment(\.tabDragTransferRegistry) private var tabDragTransferRegistry
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator {
        Coordinator(
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore, organization: organizationStore,
            buildNodes: nodeBuilder,
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
        context.coordinator.pendingWorkspaceDeletions = snapshot.pendingWorkspaceDeletions ?? [:]
        context.coordinator.pendingMachineDeletions = pendingMachineDeletions
        context.coordinator.apply(style: style)
        context.coordinator.update(inputs: CloudTreeBuildInputs(
            machines: machines,
            pendingCreates: pendingCreates, adoptedOperationIDs: adoptedOperationIDs,
            snapshot: snapshot,
            localWorkspaces: localWorkspaces,
            unreadTerminalIDs: unreadTerminalIDs,
            source: source,
            devicesSection: devicesSection,
            showsCloudVPNWarning: showsCloudVPNWarning,
            canCreateCloudMachine: canCreateCloudMachine,
            cloudMachinesUsage: cloudMachinesUsage
        ))
        context.coordinator.reveal(reveal)
        context.coordinator.reveal(creation: creationReveal)
    }
    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var machineActions: MachineRowActions
        var nodeActions: CloudTreeNodeActions
        let portsDemand = CloudPortsDiscoveryDemand()
        let expansionStore: CloudTreeExpansionStore
        let nodeCache: CloudTreeNodeCache
        private(set) var style: CloudTreeStyle = CloudTreeStyleStore.current
        private let tabDragTransferRegistry: @MainActor () -> TabDragTransferRegistry?
        private var organizationObserver: NSObjectProtocol?
        weak var outlineView: CloudTreeNSOutlineView?
        var nodes: [CloudTreeNode] = []
        let organization: CloudSidebarOrganizationStore
        private var structureSignature: [String] = []
        private var contentSignature: [CloudTreeNodeContentSnapshot] = []
        /// The selected row's stable node id, restored across in-place reloads.
        var selectedNodeID: String?
        /// Workspaces the catalog has admitted for deletion but not confirmed.
        var pendingWorkspaceDeletions: [SurfaceMachineID: Set<String>] = [:]
        var pendingMachineDeletions: Set<String> = []
        private let deletionPresentation = CloudTreeDeletionPresentation()
        var lastRevealToken: UUID?
        var creationRevealPresentation = CloudTreeCreationRevealPresentation()
        /// Which detail tab each Cloud machine has open, and the display-only
        /// regrouping of its rows around that tab row.
        var machineDetailLayout = CloudTreeMachineDetailLayout()
        private(set) var isUpdatingProgrammatically = false
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
        private(set) var isDragging = false
        var deferredNodes: [CloudTreeNode]?
        private var deferredReload = false
        var onDragStateChange: @MainActor (Bool) -> Void = { _ in }
        init(
            machineActions: MachineRowActions,
            nodeActions: CloudTreeNodeActions,
            expansionStore: CloudTreeExpansionStore,
            organization: CloudSidebarOrganizationStore? = nil,
            buildNodes: ((CloudTreeBuildInputs) -> [CloudTreeNode])? = nil,
            tabDragTransferRegistry: @escaping @MainActor () -> TabDragTransferRegistry?
        ) {
            self.machineActions = machineActions
            self.nodeActions = nodeActions
            self.expansionStore = expansionStore
            self.nodeCache = CloudTreeNodeCache(buildNodes: buildNodes)
            self.organization = organization ?? CloudSidebarOrganizationStore()
            self.tabDragTransferRegistry = tabDragTransferRegistry
            super.init()
            organizationObserver = NotificationCenter.default.addObserver(
                forName: CloudSidebarOrganizationStore.didChangeNotification,
                object: self.organization,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Organization is local sidebar state. Reapply the current
                    // immutable tree as soon as another entrypoint commits a
                    // pin, so the leading icon never waits for fleet refresh.
                    self.applyOrganization(nodes: self.organizationNodes)
                }
            }
        }
        deinit {
            if let organizationObserver { NotificationCenter.default.removeObserver(organizationObserver) }
        }
        private func discardPendingDrag(_ pending: PendingDrag) {
            pending.registration.end()
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
                activeDrag.end()
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
                activeDrag.end()
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
        /// Applies a visual preset, changing each row's geometry and content.
        func apply(style: CloudTreeStyle) {
            guard style != self.style else { return }
            self.style = style
            guard let outlineView else { return }
            if isDragging {
                deferredReload = true
                return
            }
            outlineView.treeStyle = style
            outlineView.indentationPerLevel = style.indentPerLevel
            reloadDataAndRestoreState(in: outlineView)
        }
        /// Applies the latest catalog snapshot, coalescing updates during a native drag.
        func apply(nodes: [CloudTreeNode]) {
            apply(nodes: nodes, allowDuringNativeDrag: false)
        }
        /// Applies a snapshot immediately after a destination accepted a drop.
        /// AppKit's source session may send `endedAt` later, but the destination
        /// is complete and the user should see the new order now.
        func applyOrganization(nodes: [CloudTreeNode]) {
            deferredNodes = nil
            apply(nodes: nodes, allowDuringNativeDrag: true)
        }
        private func apply(nodes: [CloudTreeNode], allowDuringNativeDrag: Bool) {
            if isDragging && !allowDuringNativeDrag {
                deferredNodes = nodes
                return
            }
            let nodes = CloudSidebarOrganizationTree(nodes: machineDetailLayout.present(nodes)).arrange(using: organization.state)
            // An optimistically hidden workspace or machine keeps its expansion
            // state and gives up its selection; a rollback restores both.
            let deletion = deletionPresentation.update(
                previous: self.nodes, next: nodes, pending: pendingWorkspaceDeletions,
                pendingMachines: pendingMachineDeletions, selectedNodeID: selectedNodeID
            )
            selectedNodeID = deletion.selectedNodeID
            expansionStore.reconcile(nodes: deletion.expansionNodes)
            let nextStructure = CloudTreeNodeBuilder.structureSignature(nodes)
            let nextContent = CloudTreeNodeBuilder.contentSignature(nodes)
            let structureUnchanged = nextStructure == structureSignature
            let contentUnchanged = nextContent == contentSignature
            #if DEBUG
            let unreadRows = CloudTreeNodeBuilder.flattened(nodes).filter {
                if case .terminal(let row) = $0.kind { return row.hasUnreadNotification }
                return false
            }.count
            cmuxDebugLog("cloudTree.apply structureChanged=\(!structureUnchanged) contentChanged=\(!contentUnchanged) unreadRows=\(unreadRows) rows=\(outlineView?.numberOfRows ?? -1)")
            #endif
            // Detail pools live outside the visible row/content signatures, so
            // a closed tab can change without changing the outline. Adopt an
            // equal-structure rebuild before the fast path or opening that tab
            // later would reveal stale rows.
            if structureUnchanged, !self.nodes.isEmpty {
                for (existing, replacement) in zip(self.nodes, nodes) {
                    existing.adopt(from: replacement)
                }
            }
            guard !structureUnchanged || !contentUnchanged else { return }
            let update = CloudTreeRowUpdate(previous: contentSignature, next: nextContent)
            contentSignature = nextContent
            if structureUnchanged, !self.nodes.isEmpty {
                portsDemand.update(nodes: self.nodes)
                guard let outlineView else { return }
                let changedRows = update.rowIndexes(in: outlineView)
                guard !changedRows.isEmpty else { return }
                withProgrammaticUpdate {
                    outlineView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
                    outlineView.noteHeightOfRows(withIndexesChanged: changedRows)
                }
                return
            }
            self.nodes = nodes
            portsDemand.update(nodes: nodes)
            structureSignature = nextStructure
            guard let outlineView else { return }
            withProgrammaticUpdate {
                outlineView.reloadData()
                restoreExpansion(in: outlineView)
                restoreSelection(in: outlineView)
            }
        }
        /// Ends a native drag and drains the latest deferred snapshot exactly once.
        private func setDragging(_ dragging: Bool) {
            guard isDragging != dragging else { return }
            isDragging = dragging
            onDragStateChange(dragging)
            guard !dragging else { return }
            let shouldReload = deferredReload
            deferredReload = false
            guard shouldReload || deferredNodes != nil else { return }
            if let deferred = deferredNodes {
                deferredNodes = nil
                if shouldReload {
                    structureSignature.removeAll(keepingCapacity: true)
                    contentSignature.removeAll(keepingCapacity: true)
                    outlineView?.treeStyle = style
                    outlineView?.indentationPerLevel = style.indentPerLevel
                }
                apply(nodes: deferred)
            } else if shouldReload, let outlineView {
                outlineView.treeStyle = style
                outlineView.indentationPerLevel = style.indentPerLevel
                reloadDataAndRestoreState(in: outlineView)
            }
        }
        private func reloadDataAndRestoreState(in outlineView: NSOutlineView) { withProgrammaticUpdate { outlineView.reloadData(); restoreExpansion(in: outlineView); restoreSelection(in: outlineView) } }
        func withProgrammaticUpdate(_ body: () -> Void) {
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
        /// Creates or reuses a cell for one immutable Cloud tree node.
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? CloudTreeNode else { return nil }
            if case .devicesEmpty(let section) = node.kind {
                let cell = (outlineView.makeView(withIdentifier: CloudTreeDevicesEmptyCell.identifier, owner: nil) as? CloudTreeDevicesEmptyCell)
                    ?? CloudTreeDevicesEmptyCell(frame: .zero)
                cell.configure(section: section, actions: nodeActions, style: style, level: outlineView.level(forItem: node))
                return cell
            }
            let cell = (outlineView.makeView(withIdentifier: CloudTreeCellView.identifier, owner: nil) as? CloudTreeCellView)
                ?? CloudTreeCellView(frame: .zero)
            var rowActions = nodeActions
            rowActions.showRowMenu = { [weak self] nodeID in self?.popUpRowMenu(nodeID: nodeID) }
            rowActions.selectMachineDetailTab = { [weak self] machine, tab in self?.toggleMachineDetailTab(tab, machine: machine) }
            cell.configure(
                node: node, machineActions: machineActions, nodeActions: rowActions, style: style,
                level: outlineView.level(forItem: node),
                panelLevel: panelLevel(of: node, in: outlineView)
            ) { [weak self] in
                self?.performPortAction($0, machineID: $1)
            }
            configureMachineReorderAccessibility(cell, node: node)
            return cell
        }

        /// The level of the machine tab row an item sits under, if any.
        private func panelLevel(of item: Any, in outlineView: NSOutlineView) -> Int? {
            guard let parent = outlineView.parent(forItem: item) as? CloudTreeNode,
                  case .machineDetailTabs = parent.kind else { return nil }
            return outlineView.level(forItem: parent)
        }

        /// An open tab's rows close only with their tab, never on their own.
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            if let node = item as? CloudTreeNode, case .machineDetailTabs = node.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = CloudTreeRowView.reusable(in: outlineView)
            row.highlightLeading = panelLevel(of: item, in: outlineView)
                .map { CloudTreeMachineDetailTabsView.panelHighlightLeading(tabRowLevel: $0, style: style) }
                ?? CloudTreeHoverStyle.leading(level: outlineView.level(forItem: item), style: style)
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            CloudTreeRowHeight(style: style).height(of: item, in: outlineView)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? CloudTreeNode)?.kind.isSelectable == true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingProgrammatically, let outlineView else { return }
            creationRevealPresentation.noteSelectionChange()
            selectedNodeID = outlineView.selectedRow >= 0
                ? (outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode)?.id
                : nil
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

        /// A double-click is the rename gesture for Cloud machines and their
        /// remote workspaces. The first click still follows the normal open
        /// path; `handleSingleClick` ignores the second click so it cannot
        /// open or toggle the row a second time.
        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? CloudTreeNode else { return }
#if DEBUG
            cmuxDebugLog("cloudTree.doubleClick row=\(row) kind=\(node.structureTag)")
#endif
            switch node.kind {
            case .machine(let machine, _):
                machineActions.promptRename(machine.id, machine.label)
            case .workspace(let machine, let workspace, _, _, _):
                nodeActions.renameWorkspace(machine, workspace)
            default:
                break
            }
        }

        func openSelection() {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode else { return }
            open(node)
        }
        /// One place decides what "open" means per row. Every surface row is
        /// `SurfaceCatalog.project` (focusing an open pane first); machine and
        /// group rows toggle. A workspace row admits its local destination
        /// through the shared optimistic open owner, while persistent create rows
        /// use this same open path. The hover "+" and context menu remain alternate
        /// entrypoints (an expired machine still prompts, and the asleep placeholder
        /// still wakes, because those rows advertise exactly that).
        func open(_ node: CloudTreeNode) {
            switch node.kind {
            case .machine(let machine, _):
                if machine.freeAccess == .expired {
                    machineActions.promptUpgrade()
                } else {
                    toggle(node)
                }
            case .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .portsGroup, .resourcesPool, .browsersGroup, .device, .devicesSection, .cloudMachinesSection:
                toggle(node)
            case .devicesEmpty, .machineDetailTabs, .machineEndSpacer:
                break
            case .createAction(let action):
                action.perform(nodeActions)
            case .pendingMachine(let operation):
                // Nothing to open yet. A failed create's click shows why (the
                // CLI transcript); a running one has nothing to say beyond its row.
                if !operation.isRunning {
                    machineActions.create.showFailure(operation.id)
                }
            case .workspace(let machine, let workspace, _, _, let openIn):
                // Open-or-focus (D13). Already showing in a local workspace -> go there
                // instead of opening a second copy; a
                // stray pane showing one of its terminals -> focus that pane.
                // Otherwise the remote workspace opens as its OWN local workspace —
                // remote and local workspaces never intermingle. D9: open never
                // creates — an empty workspace row opens nothing here; its "+" and
                // menu own creation.
                if let openIn {
                    nodeActions.selectLocalWorkspace(openIn)
                } else if let shown = CloudTreeNodeBuilder.flattened(node.children).first(where: { child in
                    if case .terminal(let row) = child.kind { return row.isOpen }
                    return false
                }), case .terminal(let openRow) = shown.kind {
                    if let view = openRow.remoteView {
                        nodeActions.projectRemoteView(openRow.resource.id, view, .tab, true)
                    } else {
                        // A terminal opens as a tab, not a new column: it joins the
                        // existing layout instead of widening it every time.
                        nodeActions.project(openRow.resource.id, .tab, true)
                    }
                } else if let group = node.dragGroup, !group.isEmpty {
                    // A workspace-row activation owns the workspace itself. It
                    // admits a local destination through the shared optimistic
                    // creation coordinator; open-here/split and drag/drop keep
                    // their explicit group destinations below.
                    nodeActions.openWorkspace(machine, workspace, group)
                }
            case .localWorkspace(let row):
                nodeActions.selectLocalWorkspace(row.workspaceID)
            case .terminal(let row):
                openTerminalRow(node, row: row)
            case .display(let resource, let openIn, let remoteView):
                // A workspace's Desktop row opens INSIDE the local workspace showing
                // that remote workspace — never a jump to a VNC pane in a different
                // workspace. Pool rows (openIn == nil) keep the global open-or-focus.
                if let openIn {
                    if let remoteView {
                        nodeActions.projectRemoteViewInLocalWorkspace(resource.id, remoteView, openIn)
                    } else {
                        nodeActions.projectInLocalWorkspace(resource.id, openIn)
                    }
                } else if let remoteView {
                    nodeActions.projectRemoteView(resource.id, remoteView, .split, true)
                } else {
                    nodeActions.project(resource.id, .split, true)
                }
            case .port(let resource, _, let openIn):
                if let openIn {
                    nodeActions.projectInLocalWorkspace(resource.id, openIn)
                } else {
                    nodeActions.project(resource.id, .split, true)
                }
            case .browser(let row):
                if let view = row.remoteView {
                    nodeActions.projectRemoteView(row.resource.id, view, .split, true)
                } else {
                    nodeActions.project(row.resource.id, .split, true)
                }
            case .resource:
                break
            case .placeholder(let machineID, let placeholder):
                if placeholder.style == .createMachine {
                    nodeActions.newMachine()
                    return
                }
                // A Ports status row (No reachable ports, asleep, Discovering…) is
                // text with its own button; only that button acts, so a click on the
                // text never refreshes or wakes.
                guard placeholder.portStatus == nil else { return }
                // "Asleep — open to wake": a fresh terminal on the machine is what wakes it.
                if placeholder.opensMachine, let machine = machine(id: machineID) { openMachine(machine) }
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

        /// Machines can sit under a section row (`.cloudMachinesSection`), so search the whole tree.
        func machine(id: SurfaceMachineID) -> MachineSnapshot? {
            for node in CloudTreeNodeBuilder.flattened(nodes) {
                if case .machine(let machine, _) = node.kind, .cloud(machine.id) == id { return machine }
            }
            return nil
        }

        // MARK: Keyboard

        func moveSelection(by delta: Int) {
            guard let outlineView, outlineView.numberOfRows > 0, delta != 0 else { return }
            let current = outlineView.selectedRow >= 0 ? outlineView.selectedRow : (delta >= 0 ? -1 : outlineView.numberOfRows)
            var target = current + delta
            while (0..<outlineView.numberOfRows).contains(target) {
                if let node = outlineView.item(atRow: target) as? CloudTreeNode, node.kind.isSelectable {
                    outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(target)
                    return
                }
                target += delta > 0 ? 1 : -1
            }
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
                guard let node = outlineView.item(atRow: row) as? CloudTreeNode, node.kind.isSelectable else { continue }
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
            for item in organizationMenuItems(for: node) + menuItems(for: node) {
                menu.addItem(item)
            }
            if let error = node.errorCopyText {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(item(CloudErrorCopy.title) { CloudErrorCopy.copy(error) })
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
            case .displaysPool(let machine, _, let canCreate):
                return displayMenuItems(machine: machine, canCreate: canCreate)
            case .workspacesGroup(let machine):
                return [
                    item(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { [nodeActions] in nodeActions.newWorkspace(machine) },
                    item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(machine, nil) },
                    item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() },
                ]
            case .workspace(let machine, let workspace, _, _, let openIn):
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
                var items = resourceMenuItems(
                    row.resource,
                    isLocal: row.resource.machine.isLocal,
                    openAction: { [weak self] in self?.open(node) },
                    remoteView: row.remoteView
                )
                if !row.resource.machine.isLocal {
                    items.append(.separator())
                    // A tab-specific row renames one view. A pool row with several
                    // views has no single safe target, so expose the explicit
                    // all-views operation. A detached zero-view resource has no
                    // daemon tab to rename and keeps this item hidden.
                    let canRename = CloudTreeOutlineView.canRenameTerminal(
                        resource: row.resource,
                        remoteView: row.remoteView
                    )
                    if canRename {
                        let title = if row.remoteView == nil {
                            String(localized: "cloudTree.menu.renameTerminalAllViews", defaultValue: "Rename all views\u{2026}")
                        } else {
                            String(localized: "cloudTree.menu.rename", defaultValue: "Rename\u{2026}")
                        }
                        items.append(item(title) { [nodeActions] in
                            nodeActions.renameTerminal(row.resource, row.remoteView)
                        })
                    }
                    items.append(item(String(localized: "cloudTree.menu.killTerminal", defaultValue: "Kill Terminal\u{2026}")) { [nodeActions] in nodeActions.closeTerminal(row.resource.id) })
                }
                return items
            case .browser(let row):
                return resourceMenuItems(
                    row.resource,
                    isLocal: row.resource.machine.isLocal,
                    openAction: { [weak self] in self?.open(node) },
                    remoteView: row.remoteView
                ) + renameRemoteViewMenuItems(resource: row.resource, remoteView: row.remoteView)
            case .display(let resource, let openIn, let remoteView):
                return resourceMenuItems(
                    resource,
                    isLocal: false,
                    openInLocalWorkspace: openIn,
                    openAction: { [weak self] in self?.open(node) },
                    remoteView: remoteView
                ) + renameRemoteViewMenuItems(resource: resource, remoteView: remoteView)
            case .port(let resource, let url, let openIn):
                return resourceMenuItems(
                    resource,
                    isLocal: false,
                    openInLocalWorkspace: openIn,
                    openAction: { [weak self] in self?.open(node) },
                    portURL: url
                )
            case .portsGroup(let machine):
                return [item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refreshMachine(machine) }]
            case .browsersGroup:
                return [item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() }]
            case .resourcesPool, .resource:
                return []
            case .placeholder(let machineID, _):
                guard let machine = machine(id: machineID) else { return [] }
                return machineMenuItems(machine)
            case .device(let row):
                return deviceMenuItems(machine: row.machine, canCreate: row.canCreateWorkspacesAndTerminals)
            case .devicesSection(let section), .devicesEmpty(let section):
                return deviceDiscoveryMenuItems(section: section)
            case .cloudMachinesSection:
                return [item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refresh() }]
            case .createAction, .machineEndSpacer: return []
            case .machineDetailTabs(let tabs):
                var items: [NSMenuItem] = []
                if tabs.machine.cloudMachineID != nil {
                    items.append(item(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) { [nodeActions] in nodeActions.newTerminal(tabs.machine, nil) })
                    if case .displaysPool(_, _, let canCreate)? = node.detailPools.first(where: { $0.structureTag == "displaysPool" })?.kind {
                        items.append(contentsOf: displayMenuItems(machine: tabs.machine, canCreate: canCreate).prefix(1))
                    }
                }
                items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { [nodeActions] in nodeActions.refreshMachine(tabs.machine) })
                return items
            }
        }

        /// The rename verb for a row whose whole identity is one daemon tab: a
        /// display or a browser. Empty when the row has no tab, which is the
        /// local case and the not-yet-placed case. Terminals do not come
        /// through here because a terminal row can stand for several tabs and
        /// needs the all-views wording.
        private func renameRemoteViewMenuItems(
            resource: SurfaceResource,
            remoteView: SurfaceRemoteView?
        ) -> [NSMenuItem] {
            guard CloudTreeOutlineView.canRenameRemoteView(resource: resource, remoteView: remoteView),
                  let remoteView
            else { return [] }
            return [
                .separator(),
                item(String(localized: "cloudTree.menu.rename", defaultValue: "Rename\u{2026}")) { [nodeActions] in
                    nodeActions.renameRemoteView(resource, remoteView)
                },
            ]
        }

        /// The verbs every surface row shares: open (reusing an open pane), open as a
        /// tab, a second pane (cloud resources only — a local terminal has one pane),
        /// and copying the resource id agents use with `cmux vm open`.
        private func resourceMenuItems(
            _ resource: SurfaceResource,
            isLocal: Bool,
            openInLocalWorkspace: UUID? = nil,
            openAction: (@MainActor () -> Void)? = nil,
            portURL: String? = nil,
            remoteView: SurfaceRemoteView? = nil
        ) -> [NSMenuItem] {
            var items: [NSMenuItem] = [
                item(String(localized: "cloudTree.menu.open", defaultValue: "Open")) { [nodeActions] in
                    // Use the exact row-open path when the row supplies one. This
                    // keeps context-menu opens in lockstep with click/Return even
                    // if a refresh changes the catalog after the menu is built.
                    if let openAction {
                        openAction()
                    } else if let openInLocalWorkspace {
                        if let remoteView {
                            nodeActions.projectRemoteViewInLocalWorkspace(resource.id, remoteView, openInLocalWorkspace)
                        } else {
                            nodeActions.projectInLocalWorkspace(resource.id, openInLocalWorkspace)
                        }
                    } else if let remoteView {
                        nodeActions.projectRemoteView(resource.id, remoteView, .split, true)
                    } else {
                        nodeActions.project(resource.id, .split, true)
                    }
                },
                item(String(localized: "cloudTree.menu.openInNewTab", defaultValue: "Open in New Tab")) { [nodeActions] in
                    if let remoteView {
                        nodeActions.projectRemoteView(resource.id, remoteView, .tab, true)
                    } else {
                        nodeActions.project(resource.id, .tab, true)
                    }
                },
            ]
            if !isLocal {
                items.append(item(String(localized: "cloudTree.menu.openInNewPane", defaultValue: "Open in New Pane")) { [nodeActions] in
                    if let remoteView {
                        nodeActions.projectRemoteView(resource.id, remoteView, .split, false)
                    } else {
                        nodeActions.project(resource.id, .split, false)
                    }
                })
            }
            items.append(.separator())
            if resource.id.isForwardedPort, !isLocal {
                // Copying the private URL never creates a forward.
                items.append(item(String(localized: "cloudTree.menu.copyPrivateURL", defaultValue: "Copy Private Address URL")) { [nodeActions] in nodeActions.copyPortLink(resource.id) })
            } else if let portURL {
                items.append(item(String(localized: "cloudTree.menu.copyLink", defaultValue: "Copy Link")) { [nodeActions] in nodeActions.copyToPasteboard(portURL) })
            } else if let port = resource.port, resource.kind == .browser {
                items.append(item(String(localized: "cloudTree.menu.copyPort", defaultValue: "Copy Port")) { [nodeActions] in nodeActions.copyToPasteboard(String(port)) })
            }
            items.append(item(String(localized: "cloudTree.menu.copySurfaceID", defaultValue: "Copy Surface ID")) { [nodeActions] in nodeActions.copyToPasteboard(resource.id.rawValue) })
            return items
        }

        func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = CloudTreeMenuItem(title: title, action: action)
            item.target = item
            return item
        }

        // MARK: Drag source

        /// Only the current native writer can reorder machines. Its captured
        /// commands retain the source account generation through live refresh.
        func machineOrdering(for info: any NSDraggingInfo, nodeID: String) -> CloudMachineOrderingActions? {
            guard isDragging, activeDragSequenceNumber == info.draggingSequenceNumber,
                  let writer = activeDragWriter,
                  let source = info.draggingSource as? NSOutlineView,
                  writer.sourceViewForDrag === source,
                  writer.string(forType: .cloudSidebarRow) == nodeID else { return nil }
            return writer.machineOrdering
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? CloudTreeNode,
                  let registration = CloudTreeDragRegistration(
                    node: node, registry: node.isDragSource ? tabDragTransferRegistry() : nil
                  ) else { return nil }
            // Do not mutate the outline while AppKit is asking for this
            // writer. The `willBeginAt` callback below is the next native
            // boundary and performs any superseded-source reclamation after
            // this data-source callback has returned.
            let writer = CloudTreeSurfaceDragPasteboardWriter(
                registration: registration,
                sourceView: outlineView,
                coordinator: self,
                provisionalToken: dragWriterOwnership.makeToken(),
                nodeID: (node.canOrganize || node.canReorderMachine) ? node.id : nil,
                machineOrdering: node.canReorderMachine ? machineActions.ordering : nil
            )
            pendingDrags[writer.provisionalToken.id] = PendingDrag(
                registration: registration,
                sourceView: outlineView,
                writer: writer
            )
            latestPendingDragWriter = writer
#if DEBUG
            cmuxDebugLog("surfaces.drag.begin drag=\(registration.id.uuidString.prefix(5)) node=\(node.id)")
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
            activeDrag = pending.registration
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
            activeDrag.end()
            self.activeDrag = nil
        }
    }
}
