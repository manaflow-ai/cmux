import CmuxRemoteSession
import Foundation

extension RemoteTmuxControlConnection {
    /// Drops tmux `#[...]` style tokens from an expanded format (tmux marks
    /// the active pane by reversing its index; the dot carries that signal
    /// here).
    static func strippingStyleTokens(_ value: String) -> String {
        value.replacingOccurrences(
            of: "#\\[[^\\]]*\\]", with: "", options: .regularExpression
        )
    }

    /// Applies tmux's authoritative window name to every topology phase that
    /// can later publish the window. Returns whether already-published state changed.
    @discardableResult
    func applyWindowName(windowId: Int, name: String) -> Bool {
        var publishedChanged = false
        if let window = windowsByID[windowId], window.name != name {
            windowsByID[windowId] = window.replacingName(with: name)
            publishedChanged = true
        }
        if var pending = pendingLayouts[windowId], pending.name != name {
            pending.name = name
            pendingLayouts[windowId] = pending
        }
        if let staged = initialBatchStaged[windowId], staged.name != name {
            initialBatchStaged[windowId] = staged.replacingName(with: name)
        }
        return publishedChanged
    }


    /// Window ids from a topology population that started with NO published
    /// windows (first attach, reconnect reseed into an empty table), still
    /// awaiting their rects reply. While non-nil, verified windows accumulate
    /// in `initialBatchStaged` and flush to `windowsByID` in ONE atomic
    /// publish when the set drains. Without the barrier, each window would
    /// publish in rects-reply arrival order, and the mirror layer's tab
    /// creation order — and with it which tab ends up selected and which
    /// mirrors take their one-time size claim from a hidden, collapsed
    /// container — would be a race between round trips.
    func applyLayout(
        windowId: Int, layout: String, visibleLayout: String? = nil, zoomed: Bool = false
    ) {
        guard let node = RemoteTmuxRawLayoutParser.parse(layout) else { return }
        // Preserve any name tmux already reported (a %layout-change carries no name).
        let existingName = windowsByID[windowId]?.name
            ?? pendingLayouts[windowId]?.name
            ?? initialBatchStaged[windowId]?.name
            ?? ""
        let visibleNode = visibleLayout.flatMap { RemoteTmuxRawLayoutParser.parse($0) }
        stagePendingLayout(
            windowId: windowId,
            node: node, visibleNode: visibleNode,
            zoomed: zoomed && visibleNode != nil,
            name: existingName
        )
    }


    /// Quarantines a parsed layout and drives the rects fetch that will
    /// publish it. Coalesces: while a fetch is in flight, newer layouts just
    /// replace the pending tree (bumping the generation) and mark it dirty
    /// for ONE follow-up fetch.
    func stagePendingLayout(
        windowId: Int,
        node: RemoteTmuxLayoutNode,
        visibleNode: RemoteTmuxLayoutNode?,
        zoomed: Bool,
        name: String
    ) {
        var pending = pendingLayouts[windowId] ?? RemoteTmuxPendingLayout(
            node: node, visibleNode: visibleNode, zoomed: zoomed, name: name, generation: 0
        )
        pending.node = node
        pending.visibleNode = visibleNode
        pending.zoomed = zoomed
        pending.name = name
        pending.generation += 1
        pending.retriesRemaining = 1
        if pending.inFlight {
            pending.dirty = true
            pendingLayouts[windowId] = pending
            return
        }
        pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
        // Send failure leaves inFlight false. Backpressure already began
        // reconnecting; the not-connected/no-writer case is recovered the
        // same way — the next (re)connect's spawn resets this table and the
        // attach list-windows restages every window. The raw tree stays
        // quarantined either way.
        pendingLayouts[windowId] = pending
        #if DEBUG
        cmuxDebugLog("remote.rects.stage @\(windowId) gen=\(pending.generation) sent=\(pending.inFlight ? 1 : 0)")
        #endif
    }


    /// Marks `windowId` resolved (published into staging, dropped, or closed)
    /// for the initial atomic batch; flushes the batch when it drains.
    func finishInitialBatchMember(_ windowId: Int) {
        guard var awaiting = initialBatchAwaiting else { return }
        awaiting.remove(windowId)
        initialBatchAwaiting = awaiting
        flushInitialBatchIfDrained()
    }


    func flushInitialBatchIfDrained() {
        guard let awaiting = initialBatchAwaiting, awaiting.isEmpty else { return }
        for (id, window) in initialBatchStaged { windowsByID[id] = window }
        rebuildPublishedPaneOwnership()
        initialBatchStaged = [:]
        initialBatchAwaiting = nil
        prunePaneState(keeping: Set(windowsByID.values.flatMap { $0.paneIDsInOrder }))
        record("initial-batch-published")
        #if DEBUG
        cmuxDebugLog("remote.rects.batchFlush windows=\(windowsByID.keys.sorted())")
        #endif
        observers.notifyTopologyChanged()
        scheduleAttachRedrawKickIfNeeded()
    }


    /// THE publication point for layout geometry — the module invariant:
    /// `windowsByID` (what observers read) only ever holds trees whose leaf
    /// rects came from list-panes. Quarantined layouts (`pendingLayouts`)
    /// are published here, generation-guarded, or not at all.
    func handlePaneRectsReply(windowId: Int, generation: Int, lines: [String]) {
        #if DEBUG
        cmuxDebugLog(
            "remote.rects.reply @\(windowId) gen=\(generation) pendingGen=\(pendingLayouts[windowId]?.generation ?? -1) "
                + "lines=\(lines.count) awaiting=\(initialBatchAwaiting.map(String.init(describing:)) ?? "nil")"
        )
        #endif
        guard var pending = pendingLayouts[windowId] else {
            // Window closed while the fetch was in flight; nothing to publish.
            return
        }
        pending.inFlight = false
        guard generation == pending.generation else {
            // Stale reply for an older layout. A newer fetch is owed: send it.
            pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
            pending.dirty = false
            pendingLayouts[windowId] = pending
            return
        }
        var rects: [Int: (x: Int, y: Int, width: Int, height: Int)] = [:]
        var labels: [Int: String] = [:]
        var activePane: Int?
        var titleRowPlacement: RemoteTmuxPaneTitleRowPlacement?
        for line in lines {
            // "%id left top width height active border-status :format…" —
            // the expanded pane-border-format is last (it may contain
            // spaces) behind the ':' sentinel (it may be empty).
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false)
            guard parts.count >= 8,
                  let paneId = RemoteTmuxControlStreamParser.id(parts[0], sigil: "%"),
                  let x = Int(parts[1]), let y = Int(parts[2]),
                  let width = Int(parts[3]), let height = Int(parts[4]),
                  width > 0, height > 0
            else { continue }
            rects[paneId] = (x: x, y: y, width: width, height: height)
            if parts[5] == "1" { activePane = paneId }
            titleRowPlacement = RemoteTmuxPaneTitleRowPlacement(rawValue: String(parts[6]))
            labels[paneId] = Self.strippingStyleTokens(String(parts[7].dropFirst()))
        }
        // The reply must cover EVERY pane of the tree it will publish:
        // `patchingLeafRects` leaves unknown leaves untouched, so a partial
        // reply (malformed line, zero-sized mid-resize rect, pane closed
        // between the layout event and this fetch) would smuggle raw
        // layout-string geometry into `windowsByID` — the exact thing the
        // quarantine exists to prevent.
        let requiredPanes = Set(pending.node.paneIDsInOrder)
            .union(pending.visibleNode.map { Set($0.paneIDsInOrder) } ?? [])
        guard !rects.isEmpty, requiredPanes.allSatisfy({ rects[$0] != nil }) else {
            // Garbled/partial reply. Retry once; then drop the pending layout —
            // observers keep the last VERIFIED tree rather than ever seeing a
            // raw one.
            if pending.retriesRemaining > 0 {
                pending.retriesRemaining -= 1
                pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
                pendingLayouts[windowId] = pending
            } else {
                pendingLayouts[windowId] = nil
                record("pane-rects-dropped @\(windowId)")
                finishInitialBatchMember(windowId)
            }
            return
        }
        for (paneId, label) in labels where paneHeaderLabels[paneId] != label {
            paneHeaderLabels[paneId] = label
        }
        if windowTitleRowPlacements[windowId] != titleRowPlacement {
            windowTitleRowPlacements[windowId] = titleRowPlacement
        }
        // The fetch's #{pane_active} is a fresh server snapshot: adopt it
        // whenever it differs, not only on first sight — an active-pane
        // change during a disconnect has no %window-pane-changed to replay,
        // so this is the path that repairs it. A user switch racing this
        // reply self-corrects: its own %window-pane-changed follows.
        if let activePane, activePaneByWindow[windowId] != activePane {
            activePaneByWindow[windowId] = activePane
            observers.emitActivePaneChanged(windowId, activePane)
        }
        let published = RemoteTmuxWindow(
            id: windowId,
            name: pending.name,
            width: pending.node.width,
            height: pending.node.height,
            layout: pending.node.patchingLeafRects(rects),
            visibleLayout: pending.visibleNode?.patchingLeafRects(rects),
            zoomed: pending.zoomed
        )
        if pending.dirty {
            // A newer layout superseded this one mid-flight: publish this
            // verified state now (it is true as of this reply) and fetch the
            // newer generation once.
            pending.dirty = false
            pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
            pendingLayouts[windowId] = pending
        } else {
            pendingLayouts[windowId] = nil
        }
        record("pane-rects @\(windowId)")
        if initialBatchAwaiting != nil {
            // First population: hold verified windows in staging and publish
            // them all at once when the last reply lands, so observers never
            // see a partial topology and tab creation stays deterministic.
            initialBatchStaged[windowId] = published
            finishInitialBatchMember(windowId)
            return
        }
        windowsByID[windowId] = published
        recordPublishedPaneOwnership(
            windowId: windowId,
            paneIds: published.paneIDsInOrder
        )
        if !windowOrder.contains(windowId) { windowOrder.append(windowId) }
        prunePaneState(keeping: Set(windowsByID.values.flatMap { $0.paneIDsInOrder }))
        observers.notifyTopologyChanged()
        // First-connect coverage for the attach redraw kick: if the grid was
        // computed before `.enter`, no post-connect `setClientSize` may ever
        // fire (layout settled + same-size dedupe upstream), so the
        // debounced-send consumer never runs. This publication is the earliest
        // point with populated topology; the geometry it holds predates tmux
        // processing the post-attach size apply, so the at-target check sees
        // the true pre-apply size. One-shot guarded — no-op when already
        // consumed (or when reseedAfterReconnect ran it).
        scheduleAttachRedrawKickIfNeeded()
    }

    func recordPublishedPaneOwnership(windowId: Int, paneIds: [Int]) {
        let livePaneIds = Set(paneIds)
        publishedWindowIdByPane = publishedWindowIdByPane.filter {
            $0.value != windowId || livePaneIds.contains($0.key)
        }
        for paneId in paneIds { publishedWindowIdByPane[paneId] = windowId }
    }

    func removePublishedPaneOwnership(windowId: Int) {
        publishedWindowIdByPane = publishedWindowIdByPane.filter { $0.value != windowId }
    }

    func prunePublishedPaneOwnership(liveWindowIds: Set<Int>) {
        publishedWindowIdByPane = publishedWindowIdByPane.filter {
            liveWindowIds.contains($0.value)
        }
    }

    func rebuildPublishedPaneOwnership() {
        publishedWindowIdByPane.removeAll(keepingCapacity: true)
        for windowId in windowOrder {
            guard let window = windowsByID[windowId] else { continue }
            for paneId in window.paneIDsInOrder { publishedWindowIdByPane[paneId] = windowId }
        }
    }


    /// Retry-or-drop for a rects fetch that errored: the pending layout must
    /// never be published raw, and must not dangle in-flight forever.
    func handlePaneRectsFailure(windowId: Int, generation: Int) {
        #if DEBUG
        cmuxDebugLog("remote.rects.error @\(windowId) gen=\(generation)")
        #endif
        guard var pending = pendingLayouts[windowId] else { return }
        pending.inFlight = false
        if pending.generation != generation || pending.dirty {
            // A newer layout is owed a fetch regardless of this failure.
            pending.dirty = false
            pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
            pendingLayouts[windowId] = pending
            return
        }
        if pending.retriesRemaining > 0 {
            pending.retriesRemaining -= 1
            pending.inFlight = requestPaneRects(windowId: windowId, generation: pending.generation)
            pendingLayouts[windowId] = pending
        } else {
            pendingLayouts[windowId] = nil
            record("pane-rects-dropped @\(windowId)")
            finishInitialBatchMember(windowId)
        }
    }


    func prunePaneState(keeping livePanes: Set<Int>) {
        paneHeaderLabels = paneHeaderLabels.filter { livePanes.contains($0.key) }
        paneOutputByteCounts = paneOutputByteCounts.filter { livePanes.contains($0.key) }
        paneForegroundStates = paneForegroundStates.filter { livePanes.contains($0.key) }
    }
}
