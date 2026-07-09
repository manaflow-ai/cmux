import Foundation

extension RemoteTmuxControlConnection {
    var lastClientSize: (columns: Int, rows: Int)? { clientSize.lastClientSize }
    var lastRequestedClientSize: (columns: Int, rows: Int)? { clientSize.lastClientSize }

    /// PER-WINDOW client sizing (`refresh-client -C '@id:WxH'`): sizes one
    /// tmux window for this control client instead of the whole session.
    func setWindowSize(windowId: Int, columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        if supportsPerWindowSize,
           let last = lastWindowSizes[windowId],
           last.columns == columns,
           last.rows == rows,
           connectionState == .connected {
            return
        }
        #if DEBUG
        cmuxDebugLog("remote.rects.claim @\(windowId) \(columns)x\(rows)")
        #endif
        lastWindowSizes[windowId] = (columns, rows)
        lastSizeRequestWindowId = windowId
        lastSizingSendAt = .now
        guard supportsPerWindowSize else {
            setClientSize(columns: columns, rows: rows)
            return
        }
        guard connectionState == .connected else { return }
        windowSizeDebounceTasks[windowId]?.cancel()
        windowSizeDebounceTasks[windowId] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self,
                  self.connectionState == .connected,
                  let size = self.lastWindowSizes[windowId]
            else { return }
            self.sendPerWindowSize(windowId: windowId, columns: size.columns, rows: size.rows)
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }

    func sendPerWindowSize(windowId: Int, columns: Int, rows: Int) {
        _ = sendInternal(
            commandBuilder.perWindowClientResizeCommand(windowId: windowId, columns: columns, rows: rows),
            kind: .perWindowSize(windowId)
        )
    }

    /// Marks the per-window sizing form unsupported and replays one deterministic
    /// latest size session-wide so old tmux servers still get a usable grid.
    func notePerWindowSizeRejected() {
        guard supportsPerWindowSize else { return }
        supportsPerWindowSize = false
        record("remote.tmux.perWindowSize unsupported; falling back to session-wide client size")
        let replay = lastSizeRequestWindowId.flatMap { lastWindowSizes[$0] } ?? lastWindowSizes.values.first
        if let replay {
            setClientSize(columns: replay.columns, rows: replay.rows)
        }
    }

    /// Runs the package session-wide redraw kick and the app-side per-window
    /// redraw kick. The per-window kick is armed on attach/reconnect and only
    /// fires for windows already at their requested grid, where a size push would
    /// otherwise be a no-op and deliver no SIGWINCH.
    func scheduleAttachRedrawKickIfNeeded() {
        clientSize.scheduleAttachRedrawKickIfNeeded()
        guard pendingPerWindowAttachRedrawKick else { return }
        guard connectionState == .connected, !windowsByID.isEmpty else { return }

        let perWindowNoOps: [(windowId: Int, columns: Int, rows: Int)] = lastWindowSizes
            .compactMap { id, size -> (windowId: Int, columns: Int, rows: Int)? in
                guard let window = windowsByID[id],
                      window.width == size.columns,
                      window.height == size.rows else { return nil }
                return (windowId: id, columns: size.columns, rows: size.rows)
            }
            .sorted { $0.windowId < $1.windowId }
        guard !perWindowNoOps.isEmpty else { return }

        let kicks = perWindowNoOps.filter { $0.rows > 2 }
        guard !kicks.isEmpty else {
            pendingPerWindowAttachRedrawKick = false
            return
        }
        pendingPerWindowAttachRedrawKick = false
        #if DEBUG
        let kickList = kicks.map { "@\($0.windowId)" }.joined(separator: ",")
        cmuxDebugLog("remote.size.kick windows=\(kickList)")
        #endif
        perWindowAttachRedrawKickTask?.cancel()
        perWindowAttachRedrawKickTask = Task { @MainActor [weak self] in
            guard let self, self.connectionState == .connected else { return }
            let liveKicks = kicks.filter { kick in
                guard let current = self.lastWindowSizes[kick.windowId] else { return false }
                return current.columns == kick.columns && current.rows == kick.rows
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
                cmuxDebugLog("remote.size.kick @\(kick.windowId) restore to \(restore.columns)x\(restore.rows)")
                #endif
                self.sendPerWindowSize(
                    windowId: kick.windowId,
                    columns: restore.columns,
                    rows: restore.rows
                )
            }
        }
    }
}
