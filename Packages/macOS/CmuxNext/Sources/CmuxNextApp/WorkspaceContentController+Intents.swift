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
            state.focusedPane[workspace.id] = pane
            if let controller = panes[pane], !controller.containsFirstResponder { controller.focusContent() }
            publishContext()
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
        case .scrollTo, .selectScreen:
            services.windows.stateDidChange(state)
        case .dropTab(let tabID, let target):
            drop(tabID, on: target)
        case .newColumn(let after, let width):
            guard let handle = handles.panes[after] else { return }
            let cwd = panes[after]?.selectedTab?.cwd
            spawnPane("new-pane-right") { try await $0.newColumn(rightOf: handle, width: width, options: SpawnOptions(cwd: cwd)) }
        case .split(let pane, let axis):
            guard let handle = handles.panes[pane] else { return }
            let cwd = panes[pane]?.selectedTab?.cwd
            let direction: SplitDirection = axis == .horizontal ? .right : .down
            let key = workspace.key
            spawnPane("split") { try await $0.split(handle, direction: direction, options: SpawnOptions(cwd: cwd, workspace: key)) }
        }
    }

    /// Runs a pane-creating command and focuses the new pane when it lands.
    private func spawnPane(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> SurfaceCreated) {
        guard let connection = daemon.connection else { return }
        Task {
            do {
                pendingFocusSurface = try await body(connection).surface
                applyCurrent()
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
        guard let (tab, _) = services.locateTab(tabID.rawValue) else { return }
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
                ?? layoutModel.screens.first { $0.id == screen }?.layout.columns.last
            guard let anchor = column?.root.panes.last, let handle = handles.panes[anchor],
                  let paneModel = daemon.store.pane(handle) else { return }
            TabMoves.toNewColumn(tab, anchor: paneModel, afterColumn: column.flatMap { handles.columns[$0.id] }, services: services, completion: restore)
        }
    }
}
