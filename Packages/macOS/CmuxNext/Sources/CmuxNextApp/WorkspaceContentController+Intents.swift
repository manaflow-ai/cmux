import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

// Layout intents -> daemon commands. Divider and column gestures carry one
// daemon `transaction` per gesture; the final value's command settles or
// rejects the gesture's LayoutTransactionID (no snapshot counting).
extension WorkspaceContentController {
    func handle(_ intent: LayoutIntent) {
        switch intent {
        case .focus(let pane):
            // Mouse-down in a pane or layout keyboard navigation.
            focus.send(.focusPane(pane.rawValue, source: .intent))
        case .setSplitRatio(let split, let ratio, let transaction, let phase):
            guard let handle = handles.splits[split] else { return layoutModel.rejectTransaction(transaction) }
            let daemonTransaction = gestureTransaction(transaction, phase: phase)
            sendGesture(transaction, phase: phase, label: "set-split-ratio") { connection in
                try await connection.setSplitRatio(handle, ratio: ratio, transaction: daemonTransaction)
            }
        case .setColumnWidth(_, let anyPane, let width, let transaction, let phase):
            guard let handle = handles.panes[anyPane] else { return layoutModel.rejectTransaction(transaction) }
            let daemonTransaction = gestureTransaction(transaction, phase: phase)
            sendGesture(transaction, phase: phase, label: "set-viewport-pane-width") { connection in
                try await connection.setColumnWidth(of: handle, width: width, transaction: daemonTransaction)
            }
        case .setColumnSticky(_, let anyPane, let sticky, let transaction):
            // Hidden until the daemon serves it; a stale intent rolls back.
            guard daemon.supports(DaemonCapabilities.shared.stickyColumns), let handle = handles.panes[anyPane] else {
                return layoutModel.rejectTransaction(transaction)
            }
            let daemonTransaction = gestureTransaction(transaction, phase: .ended)
            let wire = sticky.map(LayoutMapping.snapshot)
            sendGesture(transaction, phase: .ended, label: "set-column-sticky") { connection in
                try await connection.setColumnSticky(of: handle, sticky: wire, transaction: daemonTransaction)
            }
        case .selectScreen(let screen):
            // Every screen switch (switcher click, screen actions) focuses the
            // screen's most recently focused pane, like a tmux window's
            // active pane, through the coordinator so history and the window's
            // remembered focus move too.
            focusRememberedPane(on: screen)
            services.windows.recordSaver.stateDidChange(state)
        case .scrollTo:
            services.windows.recordSaver.stateDidChange(state)
        case .dropTab(let tabID, let target):
            drop(tabID, on: target)
        case .newColumn(let after, let width):
            guard let handle = handles.panes[after] else { return }
            let cwd = panes[after]?.selectedTab?.cwd
            let key = workspace.key
            let request = layoutModel.prepareNewColumn(nextTo: after)
            spawnPane("new-pane-right", then: { [layoutModel] in layoutModel.commitNewColumnResize(request) }) {
                try await $0.newColumn(rightOf: handle, width: width, options: SpawnOptions(cwd: cwd, workspace: key))
            }
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

    /// Runs a pane-creating command and focuses the new pane when it lands;
    /// `then` runs after it succeeded (a new column's width change).
    private func spawnPane(_ label: String, then: (@MainActor () -> Void)? = nil,
                           _ body: @escaping @Sendable (DaemonConnection) async throws -> SurfaceCreated) {
        guard let connection = daemon.connection else { return }
        let intent = beginFocusIntent()
        Task {
            do {
                expectFocus(on: try await body(connection).surface, generation: intent)
                then?()
            } catch {
                daemon.logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func gestureTransaction(_ id: LayoutTransactionID, phase: LayoutGesturePhase) -> UInt64 {
        let value: UInt64
        if let existing = gestureTransactions[id] {
            value = existing
        } else {
            nextGestureTransaction += 1
            value = nextGestureTransaction
            gestureTransactions[id] = value
        }
        if phase == .ended { gestureTransactions[id] = nil }
        return value
    }

    private func sendGesture(_ transaction: LayoutTransactionID, phase: LayoutGesturePhase, label: String,
                             _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        Task {
            let ok = await daemon.run(label, body)
            guard phase == .ended || !ok else { return }
            if ok {
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
                ?? layoutModel.screens.first { $0.id == screen }?.layout.columns.last { $0.sticky == nil }
            guard let anchor = column?.root.panes.last, let handle = handles.panes[anchor],
                  let paneModel = daemon.store.pane(handle) else { return }
            TabMoves.toNewColumn(tab, anchor: paneModel, afterColumn: column.flatMap { handles.columns[$0.id] }, services: services, completion: restore)
        }
    }
}
