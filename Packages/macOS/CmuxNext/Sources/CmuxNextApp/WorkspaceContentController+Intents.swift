import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLayout
import CmuxNextWakeups

// Layout intents -> daemon commands. A divider or column drag is local until
// it ends: its one command (the final value, one daemon `transaction`)
// settles or rejects the gesture's LayoutTransactionID (no snapshot counting).
extension WorkspaceContentController {
    /// `LayoutPaneContentProvider`: with the `pageSpringResizeOnce` feature, a page in a springing pane resizes as
    /// `browserResize.springPageResize` says. Read once per pane host, as it is made.
    var pageSpringResizing: PageSpringResizing? {
        services.features.isEnabled(.pageSpringResizeOnce)
            ? PageSpringResizing(mode: { BrowserResizeTunables.springPageResize.value }) : nil
    }

    func handle(_ intent: LayoutIntent) {
        switch intent {
        case .focus(let pane):
            // Mouse-down in a pane or layout keyboard navigation. A press in a workspace shown beside the focused one
            // (`sidebar.multiView`) focuses it first: a parked content's pane is not in the window's topology.
            if isParked, state.isOnScreenBeside(workspace.id) { services.windows.show(workspaceID: workspace.id, in: state) }
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
            sendGesture(transaction, label: "set-viewport-pane-width") { connection in
                try await connection.setColumnWidth(of: handle, width: width, transaction: daemonTransaction)
            }
        case .setColumnDock(_, let anyPane, let dock, let transaction):
            // Hidden until the daemon serves it; a stale intent rolls back.
            guard daemon.supports(DaemonCapability.dockColumns.rawValue), let handle = handles.panes[anyPane] else {
                return layoutModel.rejectTransaction(transaction)
            }
            // A top or bottom dock needs edge-docks-v1; a daemon without it
            // would refuse the edge, so the intent rolls back here.
            if dock?.edge.isBand == true, !daemon.supports(DaemonCapability.edgeDocks.rawValue) {
                return layoutModel.rejectTransaction(transaction)
            }
            let daemonTransaction = nextDaemonTransaction()
            let wire = dock.map(LayoutMapping.snapshot)
            sendGesture(transaction, label: "set-column-dock") { connection in
                try await connection.setColumnDock(of: handle, dock: wire, transaction: daemonTransaction)
            }
        case .setRowHeights(let column, let heights, let fit):
            setRowHeights(column, heights: heights, fit: fit)
        case .newRow(let below, let height):
            guard daemon.supports(DaemonCapability.rows.rawValue), let handle = handles.panes[below] else {
                return services.registry.refuse(daemon.missingCapabilityMessage(DaemonCapability.rows.rawValue))
            }
            let options = SpawnOptions(cwd: panes[below]?.selectedTab?.cwd, workspace: workspace.key)
            let command = NewRowCommand(pane: handle, height: height, options: options)
            guard command.isOptimistic(on: daemon) else {
                spawnPane("new-row") { try await RowCommands($0).newRow(below: handle, height: height, options: options) }
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
                spawnPane("split", then: { [layoutModel] in layoutModel.applySplitSizing(sizing) }) {
                    try await $0.split(handle, direction: direction, options: SpawnOptions(cwd: cwd, workspace: key))
                }
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
    func newColumn(after: LayoutPaneID, options: SpawnOptions) {
        guard let handle = handles.panes[after] else { return }
        let request = layoutModel.prepareNewColumn(nextTo: after)
        let command = NewColumnCommand(pane: handle, width: request.width, options: options)
        guard command.isOptimistic(on: daemon) else {
            spawnPane("new-pane-right", then: { [layoutModel] in layoutModel.commitNewColumnResize(request) }) { connection in
                try await connection.newColumn(rightOf: handle, width: request.width, options: options)
            }
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
        createInKeysTurn("newColumn", provisional: provisional, then: { [layoutModel] in layoutModel.commitNewColumnResize(request) }) {
            command.intendNow(on: self.daemon, provisional: provisional)
        }
    }

    /// One optimistic pane create (New Column, New Row) in the key's turn: focus expects the
    /// provisional tab, typed keys wait for it (`CreationInputCoordinator`), the intent puts it in
    /// the store, and `applyCurrent` lays it out and mounts it before the key's frame. `then` runs
    /// once the daemon made it.
    private func createInKeysTurn(_ label: String, provisional: ProvisionalPane, then: (@MainActor () -> Void)? = nil,
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
        // After the create before it (a fast second press may target its stand-in). What it lands is the rest
        // of the person's key (`personAction`).
        let previous = pendingCreate
        pendingCreate = services.mainWork.personAction(owner: "WorkspaceContent.createLanded") { () async -> Bool in
            await previous?.value
            do {
                _ = try await send()
                return true
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return false
            }
        } then: { [services, state] landed in
            if landed {
                BenchSpans.mark("\(label).reply.optimistic")
                then?()
            }
            keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window)
            // [services, state]: the task pins this controller's owners until it ends (cx-6so P1b).
            withExtendedLifetime((services, state)) {}
        }
    }

    /// Runs a pane-creating command and focuses the new pane when it lands;
    /// `then` runs after it succeeded (a new column's width change).
    private func spawnPane(_ label: String, then: (@MainActor () -> Void)? = nil,
                           _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> SurfaceCreated) {
        guard let connection = daemon.connection else { return }
        let intent = beginFocusIntent()
        // [services, state]: the task pins this controller's owners until it ends (cx-6so P1b). The
        // controller itself is weak: a reply that never comes keeps no torn-down workspace alive. The focus it
        // lands is the rest of the person's action (`personAction`).
        let logger = daemon.logger
        services.mainWork.personAction(owner: "WorkspaceContent.paneSpawned") { () async -> SurfaceCreated? in
            do {
                return try await body(connection)
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        } then: { [weak self, services, state] created in
            withExtendedLifetime((services, state)) {}
            guard let created, let self, !isTornDown else { return } // it left the window: no focus, no resize
            expectFocus(on: created.surface, generation: intent)
            then?()
        }
    }

    /// A row divider release: one typed intent in the store's log, shown
    /// over the mirror until the daemon settles or refuses it (rows.md Z1;
    /// the layout model keeps no copy).
    private func setRowHeights(_ column: LayoutColumnID, heights: [RowHeight], fit: Bool) {
        guard daemon.supports(DaemonCapability.rows.rawValue), let handle = handles.columns[column] else { return }
        var mapped: [RowHeightValue] = []
        for height in heights {
            guard let row = handles.rows[height.row] else { return }
            mapped.append(RowHeightValue(row: row, height: height.height))
        }
        let values = mapped
        // The daemon echoes the uint64 transaction as a decimal string in
        // the commit's screen-changed delta, which settles the intent.
        let wire = RowCommands.makeTransaction()
        // The intent shows in the release's turn; its command goes out in the order of the person's releases.
        let send = daemon.intendNow("set-row-heights", .setRowHeights(column: handle, heights: values),
                                    transaction: ClientTransactionID(rawValue: String(wire))) { connection in
            try await RowCommands(connection).setRowHeights(column: handle, heights: values, fit: fit, transaction: wire)
        }
        services.mainWork.personAction(owner: "WorkspaceContent.rowHeights") { _ = await send() } then: { _ in }
    }

    private func nextDaemonTransaction() -> UInt64 {
        nextGestureTransaction += 1
        return nextGestureTransaction
    }

    /// Sends a gesture's one command; its result settles or rolls back the layout's override.
    private func sendGesture(_ transaction: LayoutTransactionID, label: String, _ body: @escaping DaemonCommandBody) {
        // The command goes out in the order of the person's gestures; settling or rolling back the override is the
        // rest of the gesture (`personAction`).
        services.mainWork.personAction(owner: "WorkspaceContent.gestureSettled") { [daemon] in
            await daemon.run(label, body)
        } then: { [layoutModel] sent in
            if sent { layoutModel.settleTransaction(transaction) } else { layoutModel.rejectTransaction(transaction) }
        }
    }

    // MARK: Tab drops onto the layout

    func drop(_ tabID: LayoutTabID, on target: LayoutDropTarget) {
        // view-observation-allow: no observation; locateTab is the MachineTabIndex's one lookup
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

extension MainWorkScheduler {
    /// Runs the async rest of a person's action: a daemon command's reply, a path check, a page's read.
    ///
    /// `work` starts on the main actor in the order the person's inputs came, so the daemon commands
    /// it sends reach the connection actor in that order (`DaemonCommandBody`). `complete` runs on its
    /// result as soon as it is back, unbudgeted: p06-scheduler.md rule 2 makes the async completion of
    /// a person's action userBlocking (Chrome's `TaskPriority::USER_BLOCKING`, base/task/task_traits.h),
    /// which never waits behind pending input or a spent visible budget. Until that class
    /// lands it runs as frame work, as a person-caused observation flush does.
    ///
    /// ```swift
    /// mainWork.personAction(owner: "WorkspaceContent.gestureSettled") {
    ///     await daemon.run(label, body)
    /// } then: { sent in
    ///     sent ? layoutModel.settleTransaction(id) : layoutModel.rejectTransaction(id)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - owner: The completion's owner on the board and in the watchdog's records.
    ///   - work: The async part; it starts now, on the main actor.
    ///   - complete: The main-thread rest of the action, with what `work` returned.
    /// - Returns: The task, which ends after `complete`.
    @discardableResult
    func personAction<T, R: Sendable>(owner: String, _ work: @escaping @MainActor () async -> T,
                                      then complete: @escaping @MainActor (T) -> R) -> Task<R, Never> {
        let budget = budget, board = board
        // main-hop-allow: the rest of a person's action (p06 rule 2): starts in their input order, completes unbudgeted
        return Task {
            let value = await work()
            return budget.run(.frame, owner: board.owner(owner)) { complete(value) }
        }
    }
}
