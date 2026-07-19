import Foundation

extension RemoteTmuxControlConnection {

    @discardableResult
    func recordWindowSizeClaim(
        windowId: Int,
        columns: Int,
        rows: Int
    ) -> (columns: Int, rows: Int) {
        let previous = lastWindowSizes.updateValue((columns, rows), forKey: windowId)
        if previous?.0 == maximumWindowClaimColumns, columns < maximumWindowClaimColumns {
            maximumWindowClaimColumns = lastWindowSizes.values.reduce(0) { max($0, $1.0) }
        } else {
            maximumWindowClaimColumns = max(maximumWindowClaimColumns, columns)
        }
        if previous?.1 == maximumWindowClaimRows, rows < maximumWindowClaimRows {
            maximumWindowClaimRows = lastWindowSizes.values.reduce(0) { max($0, $1.1) }
        } else {
            maximumWindowClaimRows = max(maximumWindowClaimRows, rows)
        }
        return (maximumWindowClaimColumns, maximumWindowClaimRows)
    }

    func removeWindowSizeClaim(windowId: Int) {
        guard let removed = lastWindowSizes.removeValue(forKey: windowId) else {
            sentWindowSizes.removeValue(forKey: windowId)
            return
        }
        sentWindowSizes.removeValue(forKey: windowId)
        if removed.0 == maximumWindowClaimColumns {
            maximumWindowClaimColumns = lastWindowSizes.values.reduce(0) { max($0, $1.0) }
        }
        if removed.1 == maximumWindowClaimRows {
            maximumWindowClaimRows = lastWindowSizes.values.reduce(0) { max($0, $1.1) }
        }
        synchronizeClientSizeToWindowClaims()
    }

    func retainWindowSizeClaims(for liveWindowIDs: Set<Int>) {
        lastWindowSizes = lastWindowSizes.filter { liveWindowIDs.contains($0.key) }
        sentWindowSizes = sentWindowSizes.filter { liveWindowIDs.contains($0.key) }
        maximumWindowClaimColumns = lastWindowSizes.values.reduce(0) { max($0, $1.0) }
        maximumWindowClaimRows = lastWindowSizes.values.reduce(0) { max($0, $1.1) }
        synchronizeClientSizeToWindowClaims()
    }

    /// Keeps the control client's envelope equal to the largest live per-window claims.
    private func synchronizeClientSizeToWindowClaims() {
        guard supportsPerWindowSize,
              maximumWindowClaimColumns > 0,
              maximumWindowClaimRows > 0,
              lastClientSize?.columns != maximumWindowClaimColumns
                || lastClientSize?.rows != maximumWindowClaimRows
        else { return }
        setClientSize(
            columns: maximumWindowClaimColumns,
            rows: maximumWindowClaimRows
        )
    }

    /// Sizes the tmux control client to `columns`×`rows` cells (tmux
    /// `refresh-client -C`) so the remote windows/panes reflow to the rendered
    /// cmux grid. Without this a freshly attached session stays at ssh's default
    /// 80×24 and TUIs (claude, claude agents) render mangled. Always records the grid
    /// (re-applied by ``reseedAfterReconnect()``); sends the live `refresh-client`
    /// only while `.connected`. No-ops for a degenerate grid.
    ///
    /// This is the single sizing entrypoint every remote-tmux render path routes
    /// through (the single-pane display surface and the multi-pane window mirror),
    /// so client sizing stays one shared behavior rather than duplicated sends.
    func setClientSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        // Remember the grid so a reconnect can re-apply it (a fresh ssh client
        // otherwise reverts to 80×24 and mangles TUIs). Only send now when actually
        // connected — while reconnecting/ended there is no live stdin (the send would
        // silently drop); `reseedAfterReconnect` re-applies the stored size.
        lastClientSize = (columns, rows)
        lastSizingSendAt = .now
        guard connectionState == .connected else { return }
        // Coalesce the layout-settle oscillation into a single send: (re)arm a short
        // trailing timer; only the last size in a burst actually goes out. The fired
        // timer is also the "settled" edge that consumes the attach redraw kick.
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self, self.connectionState == .connected, let size = self.lastClientSize else { return }
            self.send("refresh-client -C \(size.columns)x\(size.rows)")
            // This send already applied the stored grid — the deferred first-connect
            // apply would only duplicate it (a deferred reconnect re-seed must stay).
            if self.pendingPostAttachAction == .applyClientSize {
                self.pendingPostAttachAction = nil
            }
            // Do NOT re-capture here. A re-capture would run capture-pane before the
            // remote app (claude) finishes its post-SIGWINCH redraw, snapshotting the
            // stale pre-resize frame and clobbering the correct redraw — the exact
            // narrow/overlap/duplicate mangle. A manual resize is clean precisely
            // because it issues no capture: it lets refresh-client -C → SIGWINCH →
            // the app's own redraw stream back and paint. Attach does the same.
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }


    /// PER-WINDOW client sizing (`refresh-client -C '@id:WxH'`): sizes ONE
    /// window for this control client instead of the whole session — each
    /// mirror owns its window's size, so two mirrored windows never fight
    /// over a shared value. Measured semantics (tmux 3.7): the pin applies
    /// exactly when this is the sole client, is sticky against session-wide
    /// pushes, caps `resize-window` per dimension, and with a co-attached
    /// real client the window sizes to the per-axis MINIMUM of all live
    /// pins and the real client — the pin is a ceiling, and %layout-change
    /// stays authoritative over what we requested. Pins are released by
    /// clean detach and by server-side client teardown; only a crash leaving
    /// zero clients freezes them (a later real client heals lazily).
    ///
    /// Dedup is per window against the last size ANY writer requested for
    /// that window. The table doubles as the reconnect reseed source:
    /// ``reseedAfterReconnect()`` re-pins every window (a fresh ssh client
    /// otherwise reverts everything to 80×24).
    ///
    /// If the server rejects the `@id:` form (`%error` — pre-3.x tmux), the
    /// connection flips to the session-wide fallback for its lifetime and
    /// surfaces the degraded mode in diagnostics; callers keep calling this
    /// method either way.
    func setWindowSize(windowId: Int, columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        // Record desired state before dedup. If a different debounced size is
        // pending and the user returns to the size already on the server, an
        // early return must cancel that stale task instead of letting it win.
        _ = recordWindowSizeClaim(windowId: windowId, columns: columns, rows: rows)
        lastSizeRequestWindowId = windowId
        guard supportsPerWindowSize else {
            setClientSize(columns: columns, rows: rows)
            return
        }
        // The CLIENT's own size must cover the largest window claim: tmux
        // derives window sizes from client sizes, and per-window pins do
        // not carry against a client still sitting at its 80-column
        // default. Track the exact live envelope upward or downward before
        // per-window dedup, because a claim change can leave this pin intact.
        synchronizeClientSizeToWindowClaims()
        // Dedup only while per-window sizing is live: on the session-wide
        // fallback the server holds ONE size, so a window's own last request
        // being unchanged does not mean the server still has it (another
        // window may have re-sized the session since).
        if supportsPerWindowSize, let sent = sentWindowSizes[windowId], sent == (columns, rows),
           connectionState == .connected {
            windowSizeDebounceTasks[windowId]?.cancel()
            windowSizeDebounceTasks[windowId] = nil
            return
        }
        #if DEBUG
        cmuxDebugLog("remote.rects.claim @\(windowId) \(columns)x\(rows)")
        #endif
        lastSizingSendAt = .now
        guard connectionState == .connected else { return }
        windowSizeDebounceTasks[windowId]?.cancel()
        windowSizeDebounceTasks[windowId] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self, self.connectionState == .connected,
                  let size = self.lastWindowSizes[windowId] else { return }
            self.sendPerWindowSize(windowId: windowId, columns: size.0, rows: size.1)
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }


    /// Sends the per-window form, tagging the command so an `%error` reply
    /// can flip the capability off and replay via the session-wide path.
    func sendPerWindowSize(windowId: Int, columns: Int, rows: Int) {
        // Record AFTER the send reports success: a send attempted while the
        // transport is down returns false, and recording it anyway makes
        // the ledger claim the server has a size it never received — dedup
        // then suppresses the retry and the claim wedges exactly the way
        // this ledger exists to prevent.
        if sendInternal(
            "refresh-client -C '@\(windowId):\(columns)x\(rows)'",
            kind: .perWindowSize(windowId)
        ) {
            sentWindowSizes[windowId] = (columns, rows)
        }
    }


    /// Marks the per-window sizing form unsupported (an `%error` came back
    /// for it) and replays the affected window's size session-wide so the
    /// session doesn't stay unsized on old servers.
    func notePerWindowSizeRejected() {
        guard supportsPerWindowSize else { return }
        supportsPerWindowSize = false
        record("remote.tmux.perWindowSize unsupported; falling back to session-wide client size")
        // Replay the most recently requested window's size — deterministic,
        // and in practice the visible tab's. (`.values.first` on a Dictionary
        // could hand the session a hidden tab's stale claim.)
        let replay = lastSizeRequestWindowId.flatMap { lastWindowSizes[$0] } ?? lastWindowSizes.values.first
        if let replay {
            setClientSize(columns: replay.0, rows: replay.1)
        }
    }


    /// One-shot, attach-only: force a real SIGWINCH when the attach size push was a
    /// no-op, so a running TUI re-renders the current frame at the current width.
    ///
    /// Why this exists: tmux's grid stores an app's output as it was RENDERED — rows
    /// drawn at an earlier window width, or an inline TUI's streaming churn, stay in
    /// the visible frame verbatim. tmux has no "redraw" command for a control (-CC)
    /// client (`%output` is an append-only pty copy; tmux never re-streams grid
    /// cells), and `capture-pane` re-reads the same stale cells, so the ONLY way to
    /// get a clean current-width frame is the app's own repaint — which apps do on
    /// SIGWINCH. A real-terminal attach virtually always delivers that SIGWINCH
    /// because its size differs from the detached window's size. The mirror's attach
    /// usually does NOT: the window still has the size cmux itself left behind, so
    /// `refresh-client -C` matches it exactly, no pane resize happens, and the stale
    /// frame stays until the user manually resizes. This kick closes that one gap by
    /// sending the same signal a real attach sends: a genuine size change (rows-1),
    /// then the true size after tmux's resize-coalescing window has passed.
    ///
    /// Ordering is safe vs the seed: the kick is scheduled after the capture-pane
    /// commands, and the tmux server processes commands FIFO, so the app's redraw
    /// `%output` always lands after (on top of) the seed paint. Skipped entirely when
    /// the attach push itself changed the window size (that already SIGWINCHes), and
    /// invisible for plain-shell panes (nothing re-renders, nothing is streamed).
    func scheduleAttachRedrawKickIfNeeded() {
        guard pendingAttachRedrawKick else { return }
        // Not ready yet (no grid computed / topology not drained): keep the one-shot
        // armed for the next size apply instead of consuming it uselessly.
        guard connectionState == .connected, !windowsByID.isEmpty else { return }
        // The size the attach applied. Per-window sizing also maintains a
        // session-wide envelope, so capability — not `lastClientSize` presence —
        // decides which kick can remain effective through tmux coalescing.
        let sessionSize = lastClientSize
        let perWindowNoOps: [(windowId: Int, columns: Int, rows: Int)] = lastWindowSizes
            .compactMap { id, size -> (windowId: Int, columns: Int, rows: Int)? in
                guard let window = windowsByID[id],
                      window.width == size.0, window.height == size.1 else { return nil }
                return (windowId: id, columns: size.0, rows: size.1)
            }
            .sorted { $0.windowId < $1.windowId }
        guard sessionSize != nil || !perWindowNoOps.isEmpty else { return }
        if !supportsPerWindowSize, let size = sessionSize {
            if size.rows <= 2 {
                pendingAttachRedrawKick = false
                return
            } else {
                // Only kick when some mirrored window ALREADY has the target size — i.e. the
                // size apply above cannot produce a SIGWINCH for it. (window-size latest makes
                // every window track the client, so one client-level kick redraws them all.)
                let windowAlreadyAtTarget = windowsByID.values.contains {
                    $0.width == size.columns && $0.height == size.rows
                }
                if !windowAlreadyAtTarget {
                    #if DEBUG
                    cmuxDebugLog("remote.size.kick skip=windowSizeDiffers target=\(size.columns)x\(size.rows)")
                    #endif
                    pendingAttachRedrawKick = false
                    return
                } else {
                    pendingAttachRedrawKick = false
                    #if DEBUG
                    cmuxDebugLog("remote.size.kick shrink to \(size.columns)x\(size.rows - 1)")
                    #endif
                    attachRedrawKickTask?.cancel()
                    attachRedrawKickTask = Task { @MainActor [weak self] in
                        guard let self, self.connectionState == .connected else { return }
                        // Bail if the user resized since the kick was scheduled: that resize is a
                        // real size change, so it already delivered the SIGWINCH this kick exists
                        // to force — and a shrink at the captured (now stale) size would flash
                        // wrong dimensions at the remote apps.
                        guard let current = self.lastClientSize, current == size else { return }
                        self.send("refresh-client -C \(size.columns)x\(size.rows - 1)")
                        do {
                            try await ContinuousClock().sleep(for: .milliseconds(Self.attachRedrawKickGapMs))
                        } catch {
                            return
                        }
                        guard self.connectionState == .connected else { return }
                        // Restore the CURRENT size (the user may have resized during the gap).
                        let restore = self.lastClientSize ?? size
                        #if DEBUG
                        cmuxDebugLog("remote.size.kick restore to \(restore.columns)x\(restore.rows)")
                        #endif
                        self.send("refresh-client -C \(restore.columns)x\(restore.rows)")
                    }
                    return
                }
            }
        }
        guard supportsPerWindowSize else {
            pendingAttachRedrawKick = false
            return
        }
        let kicks = perWindowNoOps.filter { $0.rows > 2 }
        guard !kicks.isEmpty else {
            pendingAttachRedrawKick = false
            return
        }
        pendingAttachRedrawKick = false
        #if DEBUG
        let kickList = kicks.map { "@\($0.windowId)" }.joined(separator: ",")
        cmuxDebugLog("remote.size.kick windows=\(kickList)")
        #endif
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = Task { @MainActor [weak self] in
            guard let self, self.connectionState == .connected else { return }
            // Skip any window that got a newer size meanwhile — that was a real
            // size change and already delivered the SIGWINCH for that window.
            let liveKicks = kicks.filter { kick in
                guard let current = self.lastWindowSizes[kick.windowId] else { return false }
                return current == (kick.columns, kick.rows)
            }
            guard !liveKicks.isEmpty else { return }
            for kick in liveKicks {
                #if DEBUG
                cmuxDebugLog("remote.size.kick @\(kick.windowId) shrink to \(kick.columns)x\(kick.rows - 1)")
                #endif
                self.sendPerWindowSize(windowId: kick.windowId, columns: kick.columns, rows: kick.rows - 1)
            }
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.attachRedrawKickGapMs))
            } catch {
                return
            }
            guard self.connectionState == .connected else { return }
            for kick in liveKicks {
                guard let restore = self.lastWindowSizes[kick.windowId] else { continue }
                #if DEBUG
                cmuxDebugLog("remote.size.kick @\(kick.windowId) restore to \(restore.0)x\(restore.1)")
                #endif
                self.sendPerWindowSize(windowId: kick.windowId, columns: restore.0, rows: restore.1)
            }
        }
    }
}
