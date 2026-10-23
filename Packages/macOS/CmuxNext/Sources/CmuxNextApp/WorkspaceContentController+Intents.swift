import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

// Layout intents -> daemon commands. A divider or column drag is local until
// it ends: its one command (the final value, one daemon `transaction`)
// settles or rejects the gesture's LayoutTransactionID (no snapshot counting).
extension WorkspaceContentController {
    func handle(_ intent: LayoutIntent) {
        switch intent {
        case .focus(let pane):
            // Mouse-down in a pane or layout keyboard navigation. A press in a workspace shown beside the focused one
            // (`sidebar.multiView`) focuses it first: a parked content's pane is not in the window's topology.
            if isParked, state.viewSet?.contains(workspace.id) == true { services.windows.show(workspaceID: workspace.id, in: state) }
            focus.send(.focusPane(pane.rawValue, source: .intent))
        case .setSplitRatio(let split, let ratio, let transaction, _):
            guard let handle = handles.splits[split] else { return layoutModel.rejectTransaction(transaction) }
            let daemonTransaction = nextDaemonTransaction()
            sendGesture(transaction, label: "set-split-ratio") { connection in
                try await connection.setSplitRatio(handle, ratio: ratio, transaction: daemonTransaction)
            }
        case .setColumnWidth(_, let anyPane, let width, let transaction, _):
            guard let handle = handles.panes[anyPane] else { return layoutModel.rejectTransaction(transaction) }
            let daemonTransaction = nextDaemonTransaction()
            sendGesture(transaction, label: "set-viewport-pane-width", on: handle) { connection, pane in
                try await connection.setColumnWidth(of: pane, width: width, transaction: daemonTransaction)
            }
        case .setColumnDock(_, let anyPane, let dock, let transaction):
            // Hidden until the daemon serves it; a stale intent rolls back.
            guard daemon.supports(DaemonCapabilities.dockColumns), let handle = handles.panes[anyPane] else {
                return layoutModel.rejectTransaction(transaction)
            }
            // A top or bottom dock needs edge-docks-v1; a daemon without it
            // would refuse the edge, so the intent rolls back here.
            if dock?.edge.isBand == true, !daemon.supports(DaemonCapabilities.edgeDocks) {
                return layoutModel.rejectTransaction(transaction)
            }
            let daemonTransaction = nextDaemonTransaction()
            let wire = dock.map(LayoutMapping.snapshot)
            sendGesture(transaction, label: "set-column-dock", on: handle) { connection, pane in
                try await connection.setColumnDock(of: pane, dock: wire, transaction: daemonTransaction)
            }
        case .setRowHeights(let column, let heights, let fit):
            setRowHeights(column, heights: heights, fit: fit)
        case .newRow(let below, let height):
            guard daemon.supports(DaemonCapabilities.rows), let handle = handles.panes[below] else {
                return services.registry.refuse(daemon.missingCapabilityMessage(DaemonCapabilities.rows))
            }
            let options = SpawnOptions(cwd: panes[below]?.selectedTab?.cwd, workspace: workspace.key)
            let command = NewRowCommand(pane: handle, height: height, options: options)
            guard command.isOptimistic(on: daemon) else {
                spawnPane("new-row", send: { [daemon] in try await command.send(on: daemon) })
                return
            }
            let provisional = ProvisionalPane(rowHeight: height)
            createInKeysTurn("newRow", provisional: provisional) { command.intendNow(on: self.daemon, provisional: provisional) }
        case .selectScreen(let screen):
            // Every screen switch (switcher click, screen actions) focuses the
            // screen's most recently focused pane (its active
            // pane), through the coordinator so history and the window's
            // remembered focus move too.
            focusRememberedPane(on: screen)
            services.windows.recordSaver.stateDidChange(state)
        case .scrollTo:
            services.windows.recordSaver.stateDidChange(state)
        case .cancelGesture:
            // No `.ended` will come for this gesture (its target went away); nothing of it was sent.
            return
        case .dropTab(let tabID, let target):
            drop(tabID, on: target)
        case .newColumn(let after, _):
            newColumn(after: after, options: SpawnOptions(cwd: panes[after]?.selectedTab?.cwd, workspace: workspace.key))
        case .split(let pane, let axis):
            guard let handle = handles.panes[pane], let model = daemon.store.pane(handle) else { return }
            let cwd = panes[pane]?.selectedTab?.cwd
            let direction: SplitDirection = axis == .horizontal ? .right : .down
            let key = workspace.key
            // A split stays in its column: never a new column, never a scroll.
            switch services.splitRoom(for: model, edge: axis == .horizontal ? .right : .bottom) {
            case .split:
                let sizing = layoutModel.splitSizingChanges(splitting: pane, axis: axis)
                // A split of a pending create's stand-in names its daemon pane (PaneSplitCommand.send).
                let command = PaneSplitCommand(pane: handle, direction: direction, options: SpawnOptions(cwd: cwd, workspace: key),
                                               swapTowards: nil)
                spawnPane("split", then: { [layoutModel] in layoutModel.applySplitSizing(sizing) },
                          send: { [daemon] in try await command.send(on: daemon) })
            case .newColumn:
                services.registry.refuse(RefusalStrings.columnTooNarrowToSplit)
            case .refused(let reason):
                services.registry.refuse(reason)
            }
        }
    }

    /// A new terminal column right of `after`, its shell spawned with `options` (a person's new
    /// terminal from Home's pinned dock alone, `ChatColumnPlacement.openBesideDock`).
    ///
    /// On a daemon with client keys the column shows, focused, in this turn (instant-new-surfaces,
    /// as Cmd-D's split): a provisional pane in a provisional column at the planned width, with the
    /// width changes it brings, laid out and mounted before the key's frame; the daemon's pane
    /// takes it over under the same public id. Otherwise it waits for the reply.
    ///
    /// The width changes it brings hold in the layout from the key's frame on
    /// (``LayoutModel/showNewColumnSizing(_:)``), across the handoff to the daemon's column and until
    /// the daemon's layout has them, so no frame shows a column springing back to its old width.
    func newColumn(after: LayoutPaneID, options: SpawnOptions) {
        guard let handle = handles.panes[after] else { return }
        let request = layoutModel.prepareNewColumn(nextTo: after)
        let command = NewColumnCommand(pane: handle, width: request.width, options: options)
        let sizing = layoutModel.showNewColumnSizing(request)
        let commit: @MainActor () -> Void = { [layoutModel] in layoutModel.commitNewColumnSizing(sizing) }
        let cancel: @MainActor () -> Void = { [layoutModel] in layoutModel.cancelNewColumnSizing(sizing) }
        guard command.isOptimistic(on: daemon) else {
            spawnPane("new-pane-right", then: commit, failed: cancel, send: { [daemon] in try await command.send(on: daemon) })
            return
        }
        var widths: [DaemonColumnID: Double] = [:]
        var treeWidth: Double?
        let columns = daemon.store.screen(containing: handle)?.columns ?? []
        for change in request.widthChanges {
            guard let pane = change.panes.lazy.compactMap({ self.handles.panes[$0] }).first else { continue }
            if let column = columns.first(where: { $0.layout.paneIDs.contains(pane) }) {
                widths[column.id] = change.width
            } else if columns.isEmpty {
                treeWidth = change.width
            }
        }
        let provisional = ProvisionalPane(columnWidth: request.width, widths: widths, treeWidth: treeWidth)
        createInKeysTurn("newColumn", provisional: provisional, then: commit, failed: cancel) {
            command.intendNow(on: self.daemon, provisional: provisional)
        }
    }

    /// One optimistic pane create (New Column, New Row) in the key's turn: focus expects the
    /// provisional tab, typed keys wait for it (`CreationInputCoordinator`), the intent puts it in
    /// the store, and `applyCurrent` lays it out and mounts it before the key's frame. `then` runs
    /// once the daemon made it, `failed` when it did not. A create pressed on another one's
    /// stand-in names that one's daemon pane at send time (`DaemonService.intendCreate`), so the
    /// creates of a workspace need no queue: each goes out at once, in the order pressed.
    private func createInKeysTurn(_ label: String, provisional: ProvisionalPane, then: (@MainActor () -> Void)? = nil,
                                  failed: (@MainActor () -> Void)? = nil,
                                  _ intend: () -> @MainActor () async throws -> SurfaceCreated) {
        let intent = beginFocusIntent()
        focus.expect(.tab(provisional.tabID), generation: intent)
        let window = layoutView.window
        let keyRouter = services.keyRouter
        let keys = keyRouter.creationInputCoordinator.begin(in: window, generation: intent,
                                                            earlyTab: daemon.queuesCreatingInput ? provisional.tabID : nil,
                                                            tab: provisional.tabID)
        let send = BenchSpans.measure("\(label).intend") { intend() }
        BenchSpans.measure("\(label).layout") { applyCurrent() }
        let logger = daemon.logger
        // [services, state]: the task pins this controller's owners until it ends (cx-6so P1b).
        Task { [services, state] in
            var landed = false
            defer { keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                _ = try await send()
                BenchSpans.mark("\(label).reply.optimistic")
                landed = true
                then?()
            } catch {
                failed?()
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            withExtendedLifetime((services, state)) {}
        }
    }

    /// Runs a pane-creating command and focuses the new pane when it lands;
    /// `then` runs after it succeeded (a new column's width change), `failed` when it did not.
    private func spawnPane(_ label: String, then: (@MainActor () -> Void)? = nil, failed: (@MainActor () -> Void)? = nil,
                           _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> SurfaceCreated) {
        guard let connection = daemon.connection else { failed?(); return }
        spawnPane(label, then: then, failed: failed, send: { try await body(connection) })
    }

    /// ``spawnPane(_:then:failed:_:)`` for a command that names its daemon itself (a create's
    /// reply path, which resolves a stand-in target at send time).
    private func spawnPane(_ label: String, then: (@MainActor () -> Void)? = nil, failed: (@MainActor () -> Void)? = nil,
                           send: @escaping @MainActor () async throws -> SurfaceCreated) {
        guard daemon.connection != nil else { failed?(); return }
        let intent = beginFocusIntent()
        // [services, state]: the task pins this controller's owners until it ends (cx-6so P1b).
        Task { [services, state] in
            do {
                expectFocus(on: try await send().surface, generation: intent)
                then?()
            } catch {
                failed?()
                daemon.logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            withExtendedLifetime((services, state)) {}
        }
    }

    /// A row divider release: one typed intent in the store's log, shown
    /// over the mirror until the daemon settles or refuses it (rows.md Z1;
    /// the layout model keeps no copy). On a pending New Column's or New Row's stand-in column or
    /// rows it shows at once and sends the daemon's ids once its create's records are in
    /// (``DaemonStore/daemonColumnTarget(column:heights:)``), so it never rolls back mid-motion.
    private func setRowHeights(_ column: LayoutColumnID, heights: [RowHeight], fit: Bool) {
        guard daemon.supports(DaemonCapabilities.rows), let handle = handles.columns[column] else { return }
        var mapped: [RowHeightValue] = []
        for height in heights {
            guard let row = handles.rows[height.row] else { return }
            mapped.append(RowHeightValue(row: row, height: height.height))
        }
        let values = mapped
        // The daemon echoes the uint64 transaction as a decimal string in
        // the commit's screen-changed delta, which settles the intent.
        let wire = RowCommands.makeTransaction()
        let store = daemon.store
        let send = daemon.intendNow("set-row-heights", .setRowHeights(column: handle, heights: values),
                                    transaction: ClientTransactionID(rawValue: String(wire)),
                                    prepare: { try await store.daemonColumnTarget(column: handle, heights: values) }) { connection, target in
            try await RowCommands(connection).setRowHeights(column: target.column, heights: target.heights, fit: fit, transaction: wire)
        }
        Task { _ = await send() }
    }

    private func nextDaemonTransaction() -> UInt64 {
        nextGestureTransaction += 1
        return nextGestureTransaction
    }

    /// Sends a gesture's one command; its result settles or rolls back the layout's override.
    private func sendGesture(_ transaction: LayoutTransactionID, label: String, _ body: @escaping DaemonCommandBody) {
        Task { [daemon, layoutModel] in
            if await daemon.run(label, body) {
                layoutModel.settleTransaction(transaction)
            } else {
                layoutModel.rejectTransaction(transaction)
            }
        }
    }

    /// ``sendGesture(_:label:_:)`` for a gesture on `pane`'s column, which may be a pending New
    /// Column's or New Row's stand-in: the command names the daemon's pane, waiting for it while
    /// the create is in flight (``DaemonStore/daemonTarget(for:)``). The layout's override stays
    /// pending meanwhile, so the gesture holds through the create's motion instead of the daemon
    /// refusing a stand-in's handle and the gesture snapping back.
    private func sendGesture(_ transaction: LayoutTransactionID, label: String, on pane: DaemonPaneID,
                             _ body: @escaping @Sendable (isolated DaemonConnection, DaemonPaneID) async throws -> Void) {
        Task { [daemon, layoutModel] in
            guard let target = try? await daemon.store.daemonTarget(for: pane) else {
                return layoutModel.rejectTransaction(transaction)
            }
            if await daemon.run(label, { connection in try await body(connection, target) }) {
                layoutModel.settleTransaction(transaction)
            } else {
                layoutModel.rejectTransaction(transaction)
            }
        }
    }

    // MARK: Tab drops onto the layout

    func drop(_ tabID: LayoutTabID, on target: LayoutDropTarget) {
        guard let (tab, source) = services.locateTab(tabID.rawValue) else { return }
        focus.send(.dragEnded(.dropped(tabs: [tab.id], awayFrom: source.id)))
        let restore: @MainActor (Bool) -> Void = { [services] ok in if !ok { services.restoreDetachedTab(tabID.rawValue) } }
        switch target {
        case .pane(let pane, let zone):
            guard let handle = handles.panes[pane], let paneModel = daemon.store.pane(handle) else { return }
            switch zone {
            case .center:
                TabMoves.move(tab, to: paneModel, index: paneModel.tabs.count, services: services, completion: restore)
            case .left: TabMoves.toNewSplit(tab, pane: paneModel, edge: .left, services: services, completion: restore)
            case .right: TabMoves.toNewSplit(tab, pane: paneModel, edge: .right, services: services, completion: restore)
            case .top: TabMoves.toNewSplit(tab, pane: paneModel, edge: .top, services: services, completion: restore)
            case .bottom: TabMoves.toNewSplit(tab, pane: paneModel, edge: .bottom, services: services, completion: restore)
            }
        case .newColumn(let screen, let after):
            let column = after.flatMap { id in layoutModel.screens.first { $0.id == screen }?.layout.columns.first { $0.id == id } }
                ?? layoutModel.screens.first { $0.id == screen }?.layout.columns.last { $0.dock == nil }
            guard let anchor = column?.root.panes.last, let handle = handles.panes[anchor],
                  let paneModel = daemon.store.pane(handle) else { return }
            TabMoves.toNewColumn(tab, anchor: paneModel, afterColumn: column.flatMap { handles.columns[$0.id] }, services: services, completion: restore)
        case .newDock(let screen, let edge):
            // The anchor names the screen only; the daemon places the band.
            guard let anchor = layoutModel.screens.first(where: { $0.id == screen })?.layout.panes.first,
                  let handle = handles.panes[anchor], let paneModel = daemon.store.pane(handle) else { return restore(false) }
            TabMoves.toNewDockColumn(tab, anchor: paneModel, edge: edge, services: services, completion: restore)
        }
    }
}
