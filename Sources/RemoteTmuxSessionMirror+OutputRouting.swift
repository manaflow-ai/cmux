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
            if seed.kind == .fullHistory { deferredFullPaneReseeds.remove(paneId) }
            discardPendingPaneSeedDelivery(paneId: paneId)
            routeCleanedOutput(paneId: paneId, data: renderedBytes)
            return
        }

        // A visible-only repaint cannot replace a full-history snapshot. Queue
        // it as continuation bytes so it paints only after the full seed.
        if seed.kind == .visibleRepaint,
           pendingPaneSeedKinds[paneId] == .fullHistory
        {
            let nextCount = (pendingPaneSeedByteCounts[paneId] ?? 0) + renderedBytes.count
            guard nextCount <= RemoteTmuxControlConnection.maximumPendingPaneSeedDeliveryBytes else {
                reconnectForPendingPaneSeedOverflow(paneId: paneId)
                return
            }
            guard appendPendingPaneSeedContinuation(paneId: paneId, data: renderedBytes) else {
                deferFullPaneReseed(
                    paneId: paneId,
                    event: "pane-consumer-visible-after-full-backpressure"
                )
                return
            }
            drainPendingPaneSeedDelivery(paneId: paneId)
            return
        }

        // An expired full-history seed is recovered by a newer full capture.
        // A visible repaint that completed meanwhile must not clear that marker.
        if seed.kind == .visibleRepaint,
           deferredFullPaneReseeds.contains(paneId)
        {
            connection.record("pane-consumer-visible-deferred-for-full %\(paneId)")
            retainPaneSeedReadinessSignalsIfNeeded()
            retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
            handlePaneSeedReadiness(paneId: paneId)
            return
        }

        guard !terminalGridIsReady(paneId: paneId, target: target) else {
            if seed.kind == .fullHistory { deferredFullPaneReseeds.remove(paneId) }
            discardPendingPaneSeedDelivery(paneId: paneId)
            routeCleanedOutput(paneId: paneId, data: renderedBytes)
            return
        }
        guard renderedBytes.count <= RemoteTmuxControlConnection.maximumPendingPaneSeedDeliveryBytes else {
            reconnectForPendingPaneSeedOverflow(paneId: paneId)
            return
        }
        let previousCount = pendingPaneSeedByteCounts[paneId] ?? 0
        let retainedWithoutPane = max(0, pendingPaneSeedTotalByteCount - previousCount)
        guard renderedBytes.count <= pendingPaneSeedByteLimit,
              retainedWithoutPane <= pendingPaneSeedByteLimit - renderedBytes.count else {
            deferFullPaneReseed(
                paneId: paneId,
                event: "pane-consumer-seed-total-backpressure"
            )
            return
        }

        // A newer seed of the same strength subsumes the older pending screen
        // and output, so replace rather than stacking snapshots while the grid lags.
        pendingPaneSeedBytes[paneId] = renderedBytes
        pendingPaneSeedLiveOutput[paneId] = []
        pendingPaneSeedTargetGrids[paneId] = target
        pendingPaneSeedKinds[paneId] = seed.kind
        pendingPaneSeedByteCounts[paneId] = renderedBytes.count
        pendingPaneSeedTotalByteCount = retainedWithoutPane + renderedBytes.count
        if seed.kind == .fullHistory { deferredFullPaneReseeds.remove(paneId) }
        schedulePaneSeedDeliveryDeadline(paneId: paneId)
        retainPaneSeedReadinessSignalsIfNeeded()
        retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
        // Close the check→observer-install race: the I/O thread may have applied
        // the resize after the first export and before notification retention.
        drainPendingPaneSeedDelivery(paneId: paneId)
    }

    func reconcilePendingPaneSeedDeliveries(keeping livePaneIDs: Set<Int>) {
        for paneId in Array(pendingPaneSeedBytes.keys) where !livePaneIDs.contains(paneId) {
            discardPendingPaneSeedDelivery(paneId: paneId)
        }
        deferredFullPaneReseeds.formIntersection(livePaneIDs)
        for paneId in Array(paneSeedFrameDemandReleases.keys)
        where !livePaneIDs.contains(paneId) {
            releasePaneSeedFrameDemand(paneId: paneId)
        }
        for paneId in Array(pendingPaneSeedBytes.keys) {
            guard let target = authoritativeGrid(forPane: paneId) else {
                discardPendingPaneSeedDelivery(paneId: paneId)
                continue
            }
            pendingPaneSeedTargetGrids[paneId] = target
            retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
            drainPendingPaneSeedDelivery(paneId: paneId)
        }
        for paneId in deferredFullPaneReseeds {
            retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
        }
        releasePaneSeedReadinessSignalsIfIdle()
    }

    func clearPendingPaneSeedDeliveries() {
        pendingPaneSeedBytes.removeAll(keepingCapacity: false)
        pendingPaneSeedLiveOutput.removeAll(keepingCapacity: false)
        pendingPaneSeedTargetGrids.removeAll(keepingCapacity: false)
        pendingPaneSeedKinds.removeAll(keepingCapacity: false)
        pendingPaneSeedByteCounts.removeAll(keepingCapacity: false)
        pendingPaneSeedTotalByteCount = 0
        for task in pendingPaneSeedDeadlineTasks.values { task.cancel() }
        pendingPaneSeedDeadlineTasks.removeAll(keepingCapacity: false)
        pendingPaneSeedDeadlineIDs.removeAll(keepingCapacity: false)
        deferredFullPaneReseeds.removeAll(keepingCapacity: false)
        for paneId in Array(paneSeedFrameDemandReleases.keys) {
            releasePaneSeedFrameDemand(paneId: paneId)
        }
        releasePaneSeedReadinessSignals()
    }

    private func routeOrQueueCleanedOutput(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }
        guard pendingPaneSeedBytes[paneId] != nil else {
            routeCleanedOutput(paneId: paneId, data: data)
            return
        }
        let nextCount = (pendingPaneSeedByteCounts[paneId] ?? 0) + data.count
        guard nextCount <= RemoteTmuxControlConnection.maximumPendingPaneSeedDeliveryBytes else {
            reconnectForPendingPaneSeedOverflow(paneId: paneId)
            return
        }
        guard appendPendingPaneSeedContinuation(paneId: paneId, data: data) else {
            deferFullPaneReseed(
                paneId: paneId,
                event: "pane-consumer-live-total-backpressure"
            )
            return
        }
    }

    private func appendPendingPaneSeedContinuation(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard data.count <= pendingPaneSeedByteLimit,
              pendingPaneSeedTotalByteCount <= pendingPaneSeedByteLimit - data.count else {
            return false
        }
        if pendingPaneSeedLiveOutput[paneId]?.isEmpty == false {
            pendingPaneSeedLiveOutput[paneId]![0].append(data)
        } else {
            pendingPaneSeedLiveOutput[paneId] = [data]
        }
        pendingPaneSeedByteCounts[paneId, default: 0] += data.count
        pendingPaneSeedTotalByteCount += data.count
        return true
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
        startDeferredFullPaneReseedIfReady(paneId: paneId)
    }

    private func discardPendingPaneSeedDelivery(paneId: Int) {
        let releasedCount = pendingPaneSeedByteCounts[paneId] ?? 0
        pendingPaneSeedBytes[paneId] = nil
        pendingPaneSeedLiveOutput[paneId] = nil
        pendingPaneSeedTargetGrids[paneId] = nil
        pendingPaneSeedKinds[paneId] = nil
        pendingPaneSeedByteCounts[paneId] = nil
        pendingPaneSeedTotalByteCount = max(0, pendingPaneSeedTotalByteCount - releasedCount)
        pendingPaneSeedDeadlineTasks.removeValue(forKey: paneId)?.cancel()
        pendingPaneSeedDeadlineIDs[paneId] = nil
        releasePaneSeedFrameDemandIfIdle(paneId: paneId)
        releasePaneSeedReadinessSignalsIfIdle()
    }

    private func reconnectForPendingPaneSeedOverflow(paneId: Int) {
        connection.record("pane-consumer-seed-backpressure %\(paneId)")
        connection.beginReconnecting()
    }

    private func retainPaneSeedReadinessSignalsIfNeeded() {
        guard paneSeedReadinessObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        paneSeedReadinessObserverTokens = [
            center.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let surface = notification.object as? TerminalSurface,
                          let paneId = self.tmuxPaneIdByControlSurface[surface.id] else { return }
                    self.handlePaneSeedReadiness(paneId: paneId)
                }
            },
        ]
    }

    private func handlePaneSeedReadiness(paneId: Int) {
        retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
        drainPendingPaneSeedDelivery(paneId: paneId)
        startDeferredFullPaneReseedIfReady(paneId: paneId)
        releasePaneSeedFrameDemandIfIdle(paneId: paneId)
        releasePaneSeedReadinessSignalsIfIdle()
    }

    private func schedulePaneSeedDeliveryDeadline(paneId: Int) {
        pendingPaneSeedDeadlineTasks.removeValue(forKey: paneId)?.cancel()
        let deadlineID = UUID()
        pendingPaneSeedDeadlineIDs[paneId] = deadlineID
        pendingPaneSeedDeadlineTasks[paneId] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(5))
            } catch {
                return
            }
            self?.expirePendingPaneSeedDelivery(paneId: paneId, deadlineID: deadlineID)
        }
    }

    func expirePendingPaneSeedDelivery(paneId: Int, deadlineID: UUID? = nil) {
        if let deadlineID, pendingPaneSeedDeadlineIDs[paneId] != deadlineID { return }
        guard pendingPaneSeedBytes[paneId] != nil else { return }
        drainPendingPaneSeedDelivery(paneId: paneId)
        guard pendingPaneSeedBytes[paneId] != nil else { return }
        deferFullPaneReseed(
            paneId: paneId,
            event: "pane-consumer-seed-deferred"
        )
    }

    @discardableResult
    private func startDeferredFullPaneReseedIfReady(paneId: Int) -> Bool {
        guard deferredFullPaneReseeds.contains(paneId),
              pendingPaneSeedBytes[paneId] == nil,
              let target = authoritativeGrid(forPane: paneId),
              terminalGridIsReady(paneId: paneId, target: target) else { return false }
        deferredFullPaneReseeds.remove(paneId)
        guard connection.seedPane(paneId: paneId, clearScrollback: true) != nil else {
            if connection.connectionState == .connected {
                deferredFullPaneReseeds.insert(paneId)
            }
            return false
        }
        return true
    }

    func handlePaneSeedSurfaceProgress(paneId: Int) {
        guard deferredFullPaneReseeds.contains(paneId)
                || pendingPaneSeedBytes[paneId] != nil else { return }
        retainPaneSeedReadinessSignalsIfNeeded()
        retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
        handlePaneSeedReadiness(paneId: paneId)
    }

    private func deferFullPaneReseed(paneId: Int, event: String) {
        connection.record("\(event) %\(paneId)")
        deferredFullPaneReseeds.insert(paneId)
        discardPendingPaneSeedDelivery(paneId: paneId)
        retainPaneSeedReadinessSignalsIfNeeded()
        retainPaneSeedFrameDemandIfNeeded(paneId: paneId)
        handlePaneSeedReadiness(paneId: paneId)
    }

    private func retainPaneSeedFrameDemandIfNeeded(paneId: Int) {
        guard paneSeedFrameDemandReleases[paneId] == nil,
              pendingPaneSeedBytes[paneId] != nil
                || deferredFullPaneReseeds.contains(paneId),
              let view = paneSeedSurfaceView(paneId: paneId) else { return }
        paneSeedFrameDemandReleases[paneId] = view.retainLocalRenderedFrameNotifications()
        paneSeedFrameObserverTokens[paneId] = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: view,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePaneSeedReadiness(paneId: paneId)
            }
        }
    }

    private func paneSeedSurfaceView(paneId: Int) -> GhosttyNSView? {
        if let windowId = windowIdByPane[paneId],
           let panel = windowMirrorByWindowId[windowId]?.panel(forPane: paneId) {
            return panel.hostedView.surfaceView
        }
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return nil }
        return panel.hostedView.surfaceView
    }

    private func releasePaneSeedFrameDemandIfIdle(paneId: Int) {
        guard pendingPaneSeedBytes[paneId] == nil,
              !deferredFullPaneReseeds.contains(paneId) else { return }
        releasePaneSeedFrameDemand(paneId: paneId)
    }

    private func releasePaneSeedFrameDemand(paneId: Int) {
        paneSeedFrameDemandReleases.removeValue(forKey: paneId)?()
        if let token = paneSeedFrameObserverTokens.removeValue(forKey: paneId) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func releasePaneSeedReadinessSignalsIfIdle() {
        guard pendingPaneSeedBytes.isEmpty,
              deferredFullPaneReseeds.isEmpty else { return }
        releasePaneSeedReadinessSignals()
    }

    private func releasePaneSeedReadinessSignals() {
        let center = NotificationCenter.default
        for token in paneSeedReadinessObserverTokens { center.removeObserver(token) }
        paneSeedReadinessObserverTokens.removeAll(keepingCapacity: false)
    }
}
