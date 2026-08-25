import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    /// Bounded handoff shared by every mirror, mirroring how the Ghostty OSC
    /// callback funnels into ``GhosttyDesktopNotificationIngress`` (same
    /// delivery, retargeting, and flood policy).
    static let paneNotificationIngress = GhosttyDesktopNotificationIngress()

    func routeOutput(paneId: Int, data: Data) {
        // Strip the screen/tmux `ESC k <title> ST` window-title escape that a remote
        // shell (TERM=screen*/tmux*) emits. Per-pane state survives chunk splits.
        var filter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        let cleaned = filter.filter(data)
        titleFilters[paneId] = filter
        // Intercept OSC 777/9 desktop-notification escapes (issue #833): the
        // mirror surface has no local process TTY to attribute them by, so the
        // mirror strips the sequence and delivers the notification itself,
        // attributed to this pane's surface + workspace.
        var notificationFilter = notificationFilters[paneId] ?? RemoteTmuxNotificationOSCFilter()
        let denotified = notificationFilter.filter(cleaned) { [weak self] title, body in
            self?.deliverPaneNotification(paneId: paneId, title: title, body: body)
        }
        notificationFilters[paneId] = notificationFilter
        routeOrQueueCleanedOutput(paneId: paneId, data: denotified)
    }

    /// Applies an authoritative snapshot independently from the logical live
    /// escape stream, then catches that stream up across the capture boundary.
    func routeSeed(paneId: Int, seed: RemoteTmuxPaneSeed) {
        var liveFilter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        var liveNotificationFilter = notificationFilters[paneId]
            ?? RemoteTmuxNotificationOSCFilter()
        // Seed bytes replay history (or bytes the snapshot already covers), so a
        // notification escape found here is stripped but NOT delivered — a
        // reconnect's full-history reseed must not re-fire old notifications.
        let suppressed: (String, String) -> Void = { _, _ in }
        for data in seed.discardedOutput {
            _ = liveNotificationFilter.filter(liveFilter.filter(data), onNotification: suppressed)
        }

        var snapshotFilter = RemoteTmuxScreenTitleFilter()
        var snapshotNotificationFilter = RemoteTmuxNotificationOSCFilter()
        var renderedBytes = snapshotNotificationFilter.filter(
            snapshotFilter.filter(seed.snapshot),
            onNotification: suppressed
        )
        renderedBytes.append(seed.state)
        for data in seed.catchUpOutput {
            renderedBytes.append(
                liveNotificationFilter.filter(liveFilter.filter(data), onNotification: suppressed)
            )
        }
        titleFilters[paneId] = liveFilter
        notificationFilters[paneId] = liveNotificationFilter

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
            guard nextCount <= perPanePendingSeedByteCeiling else {
                deferFullPaneReseed(
                    paneId: paneId,
                    event: "pane-consumer-visible-after-full-overflow"
                )
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
        guard renderedBytes.count <= perPanePendingSeedByteCeiling else {
            deferFullPaneReseed(paneId: paneId, event: "pane-consumer-seed-overflow")
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
        guard nextCount <= perPanePendingSeedByteCeiling else {
            deferFullPaneReseed(paneId: paneId, event: "pane-consumer-live-overflow")
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

        guard let windowId = windowIdContaining(pane: paneId),
              let mirror = windowMirrorByWindowId[windowId] else { return }
        mirror.routeOutput(paneId: paneId, data: data)
    }

    /// Delivers an intercepted OSC 777/9 notification through the same bounded
    /// ingress the Ghostty desktop-notification callback uses, attributed to the
    /// pane's mirror surface and workspace (issue #833). An empty title falls
    /// back to the workspace title downstream (`TerminalNotificationStore`).
    func deliverPaneNotification(paneId: Int, title: String, body: String) {
        guard !(title.isEmpty && body.isEmpty),
              let workspaceId = mirroredWorkspaceId else { return }
        let surfaceId = windowIdContaining(pane: paneId)
            .flatMap { windowMirrorByWindowId[$0]?.panel(forPane: paneId)?.id }
        Self.paneNotificationIngress.submit(GhosttyDesktopNotificationRequest(
            tabId: workspaceId,
            surfaceId: surfaceId,
            // No hook directory: the emitting process runs on the remote host,
            // so a local project-hook lookup would resolve the wrong config.
            hookDirectory: nil,
            title: title,
            body: body
        ))
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
        guard let windowId = windowIdContaining(pane: paneId) else { return nil }
        return windowMirrorByWindowId[windowId]?.surface(forPane: paneId)
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

    /// How many retained bytes one pane may hold.
    ///
    /// The static is a per-pane allowance: one maximum snapshot plus its bounded live catch-up. The
    /// mirror's own budget has to bound it as well, or a single pane is allowed more than the whole
    /// mirror is — which is the case today, because the mirror-wide default is exactly twice the
    /// per-pane static. One retaining pane therefore always crosses the per-pane line first, and the
    /// mirror-wide check only becomes reachable with three panes retaining at once.
    ///
    /// At the shipped default this changes nothing, since `min(x, 2x) == x`. It also makes the branch
    /// reachable from a test for the first time: the seed tests inject a small
    /// ``RemoteTmuxSessionMirror/pendingPaneSeedByteLimit`` that the per-pane comparison ignored.
    private var perPanePendingSeedByteCeiling: Int {
        min(RemoteTmuxControlConnection.maximumPendingPaneSeedDeliveryBytes, pendingPaneSeedByteLimit)
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
        guard let windowId = windowIdByPane[paneId],
              let panel = windowMirrorByWindowId[windowId]?.panel(forPane: paneId) else {
            return nil
        }
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
