import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    func routeOutput(paneId: Int, data: Data) {
        // Strip the screen/tmux `ESC k <title> ST` window-title escape that a remote
        // shell (TERM=screen*/tmux*) emits. Per-pane state survives chunk splits.
        var filter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        let cleaned = filter.filter(data)
        titleFilters[paneId] = filter
        routeOrQueueCleanedOutput(paneId: paneId, data: cleaned)
    }

    /// Applies an authoritative snapshot independently from the logical live
    /// escape stream, then catches that stream up across the capture boundary.
    func routeSeed(paneId: Int, seed: RemoteTmuxPaneSeed) {
        var liveFilter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        for data in seed.discardedOutput { _ = liveFilter.filter(data) }

        var snapshotFilter = RemoteTmuxScreenTitleFilter()
        var renderedBytes = snapshotFilter.filter(seed.snapshot)
        for data in seed.catchUpOutput {
            renderedBytes.append(liveFilter.filter(data))
        }
        titleFilters[paneId] = liveFilter
        renderedBytes.append(seed.state)

        guard let target = authoritativeGrid(forPane: paneId) else {
            discardPendingPaneSeedDelivery(paneId: paneId)
            routeCleanedOutput(paneId: paneId, data: renderedBytes)
            return
        }
        guard !terminalGridIsReady(paneId: paneId, target: target) else {
            discardPendingPaneSeedDelivery(paneId: paneId)
            routeCleanedOutput(paneId: paneId, data: renderedBytes)
            return
        }
        guard renderedBytes.count <= RemoteTmuxControlConnection.maximumPendingPaneSeedBytes else {
            reconnectForPendingPaneSeedOverflow(paneId: paneId)
            return
        }

        // A newer authoritative capture subsumes the older pending screen and
        // output, so replace rather than stacking snapshots while the grid lags.
        pendingPaneSeedBytes[paneId] = renderedBytes
        pendingPaneSeedLiveOutput[paneId] = []
        pendingPaneSeedTargetGrids[paneId] = target
        pendingPaneSeedByteCounts[paneId] = renderedBytes.count
        retainPaneSeedReadinessSignalsIfNeeded()
        // Close the check→observer-install race: the I/O thread may have applied
        // the resize after the first export and before notification retention.
        drainPendingPaneSeedDelivery(paneId: paneId)
    }

    func reconcilePendingPaneSeedDeliveries(keeping livePaneIDs: Set<Int>) {
        for paneId in Array(pendingPaneSeedBytes.keys) where !livePaneIDs.contains(paneId) {
            discardPendingPaneSeedDelivery(paneId: paneId)
        }
        for paneId in Array(pendingPaneSeedBytes.keys) {
            guard let target = authoritativeGrid(forPane: paneId) else {
                discardPendingPaneSeedDelivery(paneId: paneId)
                continue
            }
            pendingPaneSeedTargetGrids[paneId] = target
            drainPendingPaneSeedDelivery(paneId: paneId)
        }
        releasePaneSeedReadinessSignalsIfIdle()
    }

    func clearPendingPaneSeedDeliveries() {
        pendingPaneSeedBytes.removeAll(keepingCapacity: false)
        pendingPaneSeedLiveOutput.removeAll(keepingCapacity: false)
        pendingPaneSeedTargetGrids.removeAll(keepingCapacity: false)
        pendingPaneSeedByteCounts.removeAll(keepingCapacity: false)
        releasePaneSeedReadinessSignals()
    }

    private func routeOrQueueCleanedOutput(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }
        guard pendingPaneSeedBytes[paneId] != nil else {
            routeCleanedOutput(paneId: paneId, data: data)
            return
        }
        let nextCount = (pendingPaneSeedByteCounts[paneId] ?? 0) + data.count
        guard nextCount <= RemoteTmuxControlConnection.maximumPendingPaneSeedBytes else {
            reconnectForPendingPaneSeedOverflow(paneId: paneId)
            return
        }
        pendingPaneSeedLiveOutput[paneId, default: []].append(data)
        pendingPaneSeedByteCounts[paneId] = nextCount
    }

    private func routeCleanedOutput(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }

        // Multi-pane window: its in-tab renderer owns the pane's surface.
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.routeOutput(paneId: paneId, data: data)
            return
        }
        // Single-pane window: route to the window-tab's panel surface.
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.processRemoteOutput(data)
    }

    private func authoritativeGrid(forPane paneId: Int) -> (columns: Int, rows: Int)? {
        guard let windowId = windowIdContaining(pane: paneId),
              let window = connection.windowsByID[windowId] else { return nil }
        let baseLeaf = window.layout.leavesByPaneID[paneId]
        let visibleLeaf = window.zoomed ? window.visibleLayout?.leavesByPaneID[paneId] : nil
        guard let leaf = visibleLeaf ?? baseLeaf, leaf.width > 0, leaf.height > 0 else { return nil }
        return (leaf.width, leaf.height)
    }

    private func terminalSurface(forPane paneId: Int) -> TerminalSurface? {
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            return mirror.surface(forPane: paneId)
        }
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return nil }
        return panel.surface
    }

    private func terminalGridIsReady(
        paneId: Int,
        target: (columns: Int, rows: Int)
    ) -> Bool {
        guard let frame = terminalSurface(forPane: paneId)?.mobileRenderGridFrame(
            stateSeq: 0,
            scrollbackLines: 0,
            includeTheme: false
        )?.frame else { return false }
        return frame.columns >= target.columns && frame.rows >= target.rows
    }

    private func drainPendingPaneSeedDeliveries() {
        for paneId in Array(pendingPaneSeedBytes.keys) {
            drainPendingPaneSeedDelivery(paneId: paneId)
        }
        releasePaneSeedReadinessSignalsIfIdle()
    }

    private func drainPendingPaneSeedDelivery(paneId: Int) {
        guard let target = pendingPaneSeedTargetGrids[paneId],
              terminalGridIsReady(paneId: paneId, target: target),
              let seed = pendingPaneSeedBytes[paneId] else { return }
        let liveOutput = pendingPaneSeedLiveOutput[paneId] ?? []
        discardPendingPaneSeedDelivery(paneId: paneId)
        routeCleanedOutput(paneId: paneId, data: seed)
        for data in liveOutput {
            routeCleanedOutput(paneId: paneId, data: data)
        }
    }

    private func discardPendingPaneSeedDelivery(paneId: Int) {
        pendingPaneSeedBytes[paneId] = nil
        pendingPaneSeedLiveOutput[paneId] = nil
        pendingPaneSeedTargetGrids[paneId] = nil
        pendingPaneSeedByteCounts[paneId] = nil
        releasePaneSeedReadinessSignalsIfIdle()
    }

    private func reconnectForPendingPaneSeedOverflow(paneId: Int) {
        connection.record("pane-consumer-seed-backpressure %\(paneId)")
        connection.beginReconnecting()
    }

    private func retainPaneSeedReadinessSignalsIfNeeded() {
        guard paneSeedReadinessObserverTokens.isEmpty else { return }
        releasePaneSeedTickNotifications = GhosttyApp.retainTickNotifications()
        releasePaneSeedFrameNotifications = GhosttyNSView.retainRenderedFrameNotifications()
        let center = NotificationCenter.default
        paneSeedReadinessObserverTokens = [
            center.addObserver(forName: .ghosttyDidTick, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.drainPendingPaneSeedDeliveries() }
            },
            center.addObserver(forName: .ghosttyDidRenderFrame, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.drainPendingPaneSeedDeliveries() }
            },
            center.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.drainPendingPaneSeedDeliveries() }
            },
        ]
    }

    private func releasePaneSeedReadinessSignalsIfIdle() {
        guard pendingPaneSeedBytes.isEmpty else { return }
        releasePaneSeedReadinessSignals()
    }

    private func releasePaneSeedReadinessSignals() {
        let center = NotificationCenter.default
        for token in paneSeedReadinessObserverTokens { center.removeObserver(token) }
        paneSeedReadinessObserverTokens.removeAll(keepingCapacity: false)
        releasePaneSeedFrameNotifications?()
        releasePaneSeedFrameNotifications = nil
        releasePaneSeedTickNotifications?()
        releasePaneSeedTickNotifications = nil
    }
}
