import Foundation

extension RemoteTmuxControlConnection {


    func handleCommandResult(lines: [String], isError: Bool) {
        // The attach block was already consumed upstream (`attachBlockDrained`);
        // an empty FIFO here means an unsolicited block — drop it rather than
        // misalign the positional correlation.
        guard !pendingCommands.isEmpty else { return }
        let kind = pendingCommands.removeFirst()
        #if DEBUG
        switch kind {
        case .paneRects, .listWindows, .perWindowSize:
            cmuxDebugLog(
                "remote.fifo.dequeue \(kind) depth=\(pendingCommands.count)"
                    + " err=\(isError ? 1 : 0) lines=\(lines.count)"
                    + " bytes=\(lines.reduce(0) { $0 + $1.utf8.count })"
            )
        default:
            break
        }
        #endif
        defer {
            if case .listWindows = kind {
                completeWindowListRequest()
            }
        }
        guard !isError else {
            // An errored activity query must still complete (with nil) — a close
            // decision is waiting on it and falls back to the cached state.
            if case let .activityQuery(token) = kind,
               let completion = activityQueryCompletions.removeValue(forKey: token) {
                completion(nil)
            }
            if case let .newWindow(token) = kind,
               let completion = newWindowCompletions.removeValue(forKey: token) {
                completion(nil)
            }
            // A rejected per-window size normally means the server predates
            // the '@id:WxH' form: degrade to session-wide sizing, visibly.
            // But a "can't find window" error is about ONE dead window (it
            // raced a close) — drop that entry instead of downgrading the
            // whole connection.
            if case let .perWindowSize(windowId) = kind {
                if lines.joined(separator: " ").localizedCaseInsensitiveContains("find window") {
                    removeWindowSizeClaim(windowId: windowId)
                } else {
                    notePerWindowSizeRejected()
                }
            }
            // An errored rects fetch still owes its pending layout a
            // resolution: retry once, then drop the pending tree so
            // observers keep the last VERIFIED layout (never a raw one).
            if case let .paneRects(windowId, generation) = kind {
                handlePaneRectsFailure(windowId: windowId, generation: generation)
            }
            if case let .windowReorder(isLast) = kind {
                completeWindowReorderCommand(isLast: isLast, failed: true)
            }
            if case let .listWindows(requestGeneration, retainedPaneIDs) = kind {
                if windowReorderRecoveryGeneration == requestGeneration {
                    restartAfterWindowReorderRecoveryFailure()
                } else if !retainedPaneIDs.isEmpty {
                    record("window-list-retention-reconnect")
                    beginReconnecting()
                }
            }
            if case .listWindowOrder = kind {
                requestFullWindowOrderRecovery()
            }
            // Errors are dropped by design (results correlate positionally), but
            // an invisible %error has already hidden one real bug — an unquoted
            // refresh-client -B that never subscribed — so leave a trace.
            #if DEBUG
            cmuxDebugLog(
                "remote.tmux.commandError kind=\(kind) error=\"\(lines.joined(separator: " / "))\""
            )
            #endif
            return
        }
        switch kind {
        case let .newWindow(token):
            guard let completion = newWindowCompletions.removeValue(forKey: token) else { break }
            let windowId = lines.first.flatMap {
                RemoteTmuxControlStreamParser.id(Substring($0), sigil: "@")
            }
            completion(windowId)
        case let .paneRects(windowId, generation):
            handlePaneRectsReply(windowId: windowId, generation: generation, lines: lines)
        case let .listWindows(requestGeneration, retainedPaneIDs):
            // A pending order verification owns the window-order ledger: an
            // incidental topology refetch (e.g. a %window-add landing mid-batch)
            // shares the current generation tag, and letting it replace the
            // optimistic order would make the follow-up `listWindowOrder`
            // verification compare the server order against itself — reporting
            // success for a reorder that never reached the desired order.
            let completesReorderRecovery = windowReorderRecoveryGeneration == requestGeneration
            let shouldApplyWindowOrder = requestGeneration == windowReorderGeneration
                && (windowReorderVerificationGeneration == nil || completesReorderRecovery)
            var order: [Int] = []
            var next: [Int: RemoteTmuxWindow] = [:]
            for line in lines {
                // "@<id> <layout> <visible-layout> [<flags>] <name with spaces…>"
                // — id and the layout strings never contain spaces; flags are
                // bracket-delimited because they can be EMPTY (an empty bare
                // field would collapse under whitespace splitting).
                let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
                guard parts.count >= 4,
                      let id = RemoteTmuxControlStreamParser.id(parts[0], sigil: "@"),
                      let node = RemoteTmuxRawLayoutParser.parse(String(parts[1]))
                else { continue }
                let visibleNode = RemoteTmuxRawLayoutParser.parse(String(parts[2]))
                let flags = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let name = parts.count >= 5 ? String(parts[4]) : ""
                next[id] = RemoteTmuxWindow(
                    id: id,
                    name: name,
                    width: node.width,
                    height: node.height,
                    layout: node,
                    visibleLayout: visibleNode,
                    zoomed: flags.contains("Z") && visibleNode != nil
                )
                order.append(id)
            }
            // `next` holds RAW string geometry — it is never published as-is.
            // Each window is staged and re-published by its own rects reply;
            // until then observers keep that window's previous verified tree
            // (or, for a brand-new window, don't see it yet).
            // Ignore an empty/garbled reply on purpose: a live tmux session always
            // has ≥1 window, so a zero-window parse is a transient or malformed
            // result, not a real topology. Acting on it would wipe `windowOrder`
            // and tear down every mirror tab. A genuine "no windows" state means
            // the session ended — that arrives as the connection's `%exit` /
            // stream-end (see `handleConnectionExited` → `handleSessionEndedRemotely`),
            // which is the path that closes the workspace / dedicated window.
            if !order.isEmpty {
                // Replace topology instead of merging: a remote close missed while
                // disconnected leaves no %window-close, so prune stale panes here.
                let liveIDs = Set(order)
                let optimisticLiveOrder = windowOrder.filter { liveIDs.contains($0) }
                // REMOVALS and name updates publish now (they carry no leaf
                // geometry); every window's GEOMETRY is staged and published
                // only by its rects reply. Verified entries for surviving
                // windows stay as-is until then.
                windowsByID = windowsByID.filter { liveIDs.contains($0.key) }
                prunePublishedPaneOwnership(liveWindowIds: liveIDs)
                pendingLayouts = pendingLayouts.filter { liveIDs.contains($0.key) }
                // A population that starts from an empty table (first attach,
                // reconnect reseed after every window closed) publishes
                // atomically: hold each window's verified tree in staging
                // until the LAST rects reply lands. Otherwise tab creation
                // order — and initial selection — would follow reply arrival
                // order, not tmux's window order.
                initialBatchStaged = initialBatchStaged.filter { liveIDs.contains($0.key) }
                if windowsByID.isEmpty {
                    initialBatchAwaiting = Set(order).subtracting(initialBatchStaged.keys)
                    #if DEBUG
                    cmuxDebugLog("remote.rects.batchArm windows=\(order)")
                    #endif
                } else if var awaiting = initialBatchAwaiting {
                    awaiting.formIntersection(liveIDs)
                    initialBatchAwaiting = awaiting
                    flushInitialBatchIfDrained()
                }
                for (id, window) in next {
                    applyWindowName(windowId: id, name: window.name)
                    stagePendingLayout(
                        windowId: id,
                        node: window.layout, visibleNode: window.visibleLayout,
                        zoomed: window.zoomed, name: window.name
                    )
                }
                // This complete snapshot decides only the close gaps already
                // represented when its request was sent. A later overlapping
                // close remains retained for its own snapshot.
                paneIDsRetainedUntilWindowList.subtract(retainedPaneIDs)
                // Per-window sizing state must not outlive the topology: a
                // stale pin would be replayed by the reconnect reseed, and a
                // pending debounce could fire at a dead @id.
                retainWindowSizeClaims(for: liveIDs)
                for (id, task) in windowSizeDebounceTasks where !liveIDs.contains(id) {
                    task.cancel()
                    windowSizeDebounceTasks[id] = nil
                }
                if let last = lastSizeRequestWindowId, !liveIDs.contains(last) {
                    lastSizeRequestWindowId = nil
                }
                activePaneByWindow = activePaneByWindow.filter { liveIDs.contains($0.key) }
                windowTitleRowPlacements = windowTitleRowPlacements.filter { liveIDs.contains($0.key) }
                prunePaneState(keeping: Set(next.values.flatMap { $0.paneIDsInOrder }))
                #if DEBUG
                cmuxDebugLog(
                    "remote.window.snapshot order=\(order)"
                        + " prior=\(windowOrder)"
                )
                #endif
                windowOrder = shouldApplyWindowOrder
                    ? order
                    : decoding.windowOrder(order, applyingReorder: optimisticLiveOrder)
                if completesReorderRecovery {
                    windowReorderRecoveryGeneration = nil
                    // The batch that escalated here is judged against the
                    // recovered authoritative order rather than failed outright:
                    // the escalation cause (membership change mid-batch) says
                    // nothing about whether the swaps landed. Compare only the
                    // windows the batch actually ordered, so a window that
                    // appeared or closed mid-flight doesn't fail a reorder tmux
                    // in fact applied (and e.g. roll back pin state for it).
                    if let generation = windowReorderVerificationGeneration {
                        let desiredSet = Set(optimisticLiveOrder)
                        finishWindowReorderVerification(
                            generation: generation,
                            succeeded: order.filter { desiredSet.contains($0) } == optimisticLiveOrder
                        )
                    }
                }
                // Publish removals/order/names; geometry rides each window's
                // rects reply.
                observers.notifyTopologyChanged()
                // The attach block is drained and the topology is fresh — run the
                // deferred post-attach work; commands queued here correlate cleanly
                // (see ``PostAttachAction``).
                switch pendingPostAttachAction {
                case .reseed:
                    reseedAfterReconnect()
                case .applyClientSize:
                    // A surface that hasn't computed a grid yet is covered by the
                    // debounced `setClientSize` instead.
                    if let size = lastClientSize {
                        send("refresh-client -C \(size.columns)x\(size.rows)")
                    }
                case nil:
                    break
                }
                pendingPostAttachAction = nil
                // First-connect coverage for the attach redraw kick happens at
                // the publication point (each window's rects reply): here
                // `windowsByID` is still empty on a first connect — geometry
                // publishes only when the rects replies land.
            } else if completesReorderRecovery {
                restartAfterWindowReorderRecoveryFailure()
            } else if !retainedPaneIDs.isEmpty {
                record("window-list-retention-reconnect")
                beginReconnecting()
            }
        case let .listWindowOrder(requestGeneration):
            let order = lines.compactMap { line in
                RemoteTmuxControlStreamParser.id(
                    Substring(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                    sigil: "@"
                )
            }
            let knownWindowIDs = Set(windowsByID.keys)
            guard !order.isEmpty,
                  order.count == knownWindowIDs.count,
                  Set(order) == knownWindowIDs else {
                // A concurrent add/close needs the existing full topology path.
                requestFullWindowOrderRecovery()
                break
            }
            let optimisticOrder = windowOrder.filter { knownWindowIDs.contains($0) }
            finishWindowReorderVerification(
                generation: requestGeneration,
                succeeded: requestGeneration == windowReorderGeneration && order == windowOrder
            )
            let reconciledOrder = requestGeneration == windowReorderGeneration
                ? order
                : decoding.windowOrder(order, applyingReorder: optimisticOrder)
            if reconciledOrder != windowOrder {
                windowOrder = reconciledOrder
                observers.notifyTopologyChanged()
            }
        case let .capturePane(paneId):
            // capture-pane -e -S output is the pane's history + visible rows (with
            // SGR escapes). Home + clear the VISIBLE SCREEN (ESC[2J — NOT ESC[3J,
            // which would erase the scrollback we are seeding), then write every
            // captured row joined by CR LF: rows that overflow the screen scroll up
            // into the surface's scrollback buffer, which is what makes the mirrored
            // tab scrollable from the start. The last row (the visible bottom) gets
            // no trailing newline so the cursor lands at its END, lining up with
            // tmux's real prompt cursor — otherwise echoed input lands a line below
            // the prompt. The `.paneState` seed then repositions the cursor within
            // the visible screen.
            let painted = "\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
            if let data = painted.data(using: .utf8) {
                observers.emitPaneOutput(paneId, data)
            }
        case let .paneState(paneId):
            // Restore the pane's terminal state (scroll region + DEC modes + cursor)
            // onto the mirror surface, applied after the capture paint. The scroll
            // region (DECSTBM) is the important one: without it an inline TUI's
            // region-relative redraws land on the wrong rows even at a static size.
            if let line = lines.first {
                observers.emitPaneOutput(paneId, decoding.paneStateSeedSequence(from: line))
            }
        case let .panePath(paneId):
            if let path = lines.first?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                observers.emitPaneCwd(paneId, path)
            }
        case let .paneReflow(paneId):
            // One-shot reflow classification result (see requestPaneReflow). Empty
            // lines → classifyAndEmitReflow defaults to no-reflow (safe).
            classifyAndEmitReflow(paneId: paneId, rawValue: lines.first ?? "", source: "oneshot")
        case let .activityQuery(token):
            guard let completion = activityQueryCompletions.removeValue(forKey: token) else { break }
            var states: [Int: PaneForegroundState] = [:]
            for line in lines {
                guard let parsed = Self.parseActivityQueryLine(line) else { continue }
                states[parsed.paneId] = parsed.state
            }
            // The fresh answer flows back into the cache, so the synchronous
            // consumers (batch close, workspace close, quit warning) benefit too.
            for (paneId, state) in states { paneForegroundStates[paneId] = state }
            completion(states)
        case let .paneAltScreen(paneId):
            // Match the mirror surface to the remote pane's screen (alt = no reflow on
            // resize). Emitted before the capture paint that follows in the FIFO, so the
            // seeded rows land on the right screen. The else branch is load-bearing on a
            // surface REUSED across reconnect: if it was on the alt screen before and the
            // remote pane is now on primary, force it back (1049l) so the capture doesn't
            // paint onto a stale alt screen.
            if lines.first?.trimmingCharacters(in: .whitespaces) == "1" {
                observers.emitPaneOutput(paneId, Self.altScreenEnterSequence)
            } else {
                observers.emitPaneOutput(paneId, Self.altScreenExitSequence)
            }
        case .perWindowSize:
            // A successful per-window size push replies with an empty block;
            // the interesting outcome (%error -> capability fallback) is
            // handled in the error branch above.
            break
        case let .windowReorder(isLast):
            completeWindowReorderCommand(isLast: isLast, failed: false)
        case .other:
            break
        }
    }

    /// Verifies a successful reorder without restaging every window's geometry.
    func requestWindowOrder() {
        guard let generation = windowReorderVerificationGeneration else { return }
        guard sendInternal(
            "list-windows -F \"#{window_id}\"",
            kind: .listWindowOrder(reorderGeneration: generation)
        ) else {
            finishWindowReorderVerification(generation: generation, succeeded: false)
            return
        }
    }

    /// Escalates a failed order-only verification to blocking full recovery.
    /// The pending verification is NOT failed here: escalation means the cheap
    /// check was inconclusive (membership changed, malformed reply), so the
    /// batch is resolved against the recovery's authoritative order instead.
    /// A recovery that itself fails reconnects, which fails the verification.
    func requestFullWindowOrderRecovery() {
        windowReorderRecoveryGeneration = windowReorderGeneration
        requestWindows()
    }

    /// Reconciles every completed batch while rejected swaps use full recovery.
    func completeWindowReorderCommand(isLast: Bool, failed: Bool) {
        windowReorderBatchFailed = windowReorderBatchFailed || failed
        guard isLast else { return }
        if windowReorderBatchFailed {
            requestFullWindowOrderRecovery()
        } else {
            requestWindowOrder()
        }
        windowReorderBatchFailed = false
    }

    func failPendingNewWindowRequests() {
        let completions = Array(newWindowCompletions.values)
        newWindowCompletions.removeAll()
        completions.forEach { $0(nil) }
    }

    func finishWindowReorderVerification(generation: UInt64, succeeded: Bool) {
        if windowReorderVerificationGeneration == generation {
            windowReorderVerificationGeneration = nil
        }
        windowReorderVerifications.removeValue(forKey: generation)?(succeeded)
    }

    func failPendingWindowReorderVerifications() {
        let verifications = windowReorderVerifications.sorted { $0.key < $1.key }
        windowReorderVerificationGeneration = nil
        windowReorderVerifications.removeAll()
        verifications.forEach { $0.value(false) }
    }
}
