import CmuxRemoteSession
import Foundation

extension RemoteTmuxControlConnection {
    /// How many lines of pane history `capture-pane` seeds onto a freshly mounted
    /// (or reconnected) mirror surface. Clamped by the remote pane's `history-limit`.
    private static let scrollbackCaptureLines = 5_000

    /// Sends a tmux command on the control stream (newline-terminated).
    @discardableResult
    func send(_ command: String) -> Bool {
        sendInternal(command, kind: .other)
    }

    // MARK: - Mirror session environment (issue #833)

    /// Marker signalling to remote shell integration that this tmux session is
    /// mirrored by a local cmux over ssh-tmux (`tmux -CC`, no relay socket).
    static let mirrorMarkerEnvironmentKey = "CMUX_REMOTE_TMUX_MIRROR"

    /// Pushes the mirror marker + identity pairs into the remote tmux SESSION
    /// environment. Called from the first post-attach `list-windows` result, so
    /// both paths — first connect and every reconnect — refresh values that
    /// would otherwise go permanently stale after an app relaunch (issue #833:
    /// the `tmux -CC` attach has no cmux wrapper shell outside tmux on the
    /// remote, so nobody else ever re-publishes them).
    ///
    /// Deliberately NOT pushed: `CMUX_SOCKET_PATH`. The ssh-tmux transport has
    /// no relay/reverse forward, so the local Mac socket path is meaningless on
    /// the remote host; publishing it would point remote `cmux` CLI invocations
    /// at a dead socket. Notification delivery instead rides the OSC 777/9
    /// intercept in ``RemoteTmuxSessionMirror`` (see
    /// ``RemoteTmuxNotificationOSCFilter``).
    ///
    /// Session scope (`-t`, not `-g`): the shell-integration refresh path runs
    /// a session-scoped `show-environment`, which does not surface `-g` values.
    func pushMirrorSessionEnvironment() {
        // Target by the stable session id when known so the push can't race a
        // rename (same convention as `rename-session`).
        guard let target = sessionId.map({ "$\($0)" })
            ?? RemoteTmuxHost.controlModeLineSafeName(sessionName)
                .map(RemoteTmuxHost.shellSingleQuoted)
        else { return }
        var pairs = mirrorEnvironment
        pairs[Self.mirrorMarkerEnvironmentKey] = "1"
        let commands = Self.mirrorEnvironmentCommands(target: target, pairs: pairs)
        guard !commands.isEmpty else { return }
        _ = sendBatchInternal(commands, kinds: commands.map { _ in .other })
    }

    /// Builds the `set-environment -t <target> KEY VALUE` command lines for a
    /// push, dropping any pair that could break the line-oriented control
    /// stream. Pure (and deterministic — sorted by key) so tests can pin the
    /// exact wire format.
    static func mirrorEnvironmentCommands(
        target: String,
        pairs: [String: String]
    ) -> [String] {
        pairs.sorted { $0.key < $1.key }.compactMap { key, value in
            // Keys are ours (static identifiers), but guard anyway: one CR/LF
            // would terminate the command line before tmux parses the quotes.
            guard RemoteTmuxHost.controlModeLineSafeName(key) != nil,
                  !key.contains(" "),
                  RemoteTmuxHost.controlModeLineSafeName(value) != nil
            else { return nil }
            return "set-environment -t \(target) \(key) "
                + RemoteTmuxHost.shellSingleQuoted(value)
        }
    }

    /// Sends a command and reports how its `%begin`/`%end` block resolved:
    /// `true` on `%end`, `false` on `%error` — or `false` if the stream resets
    /// before the block arrives, since a fresh control stream can never answer
    /// it. A `false` RETURN means the command never left; the completion is
    /// then not called. Callers get exactly one edge either way, so state
    /// machines can anchor on the block resolution instead of a timer.
    @discardableResult
    func sendTracked(_ command: String, completion: @escaping (Bool) -> Void) -> Bool {
        let token = UUID()
        trackedSendCompletions[token] = completion
        guard sendInternal(command, kind: .tracked(token)) else {
            trackedSendCompletions.removeValue(forKey: token)
            return false
        }
        return true
    }

    func failPendingTrackedSends() {
        let completions = Array(trackedSendCompletions.values)
        trackedSendCompletions.removeAll()
        completions.forEach { $0(false) }
    }

    /// Atomically enqueues a window-reorder batch and its result correlation.
    func sendWindowReorder(
        _ commands: [String],
        verification: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard !commands.isEmpty else {
            verification?(true)
            return true
        }
        guard windowReorderRecoveryGeneration == nil,
              windowReorderVerificationGeneration == nil else { return false }
        let kinds: [CommandKind] = commands.indices.map {
            .windowReorder(isLast: $0 == commands.index(before: commands.endIndex))
        }
        guard sendBatchInternal(commands, kinds: kinds) else { return false }
        windowReorderGeneration &+= 1
        windowReorderVerificationGeneration = windowReorderGeneration
        windowReorderVerifications[windowReorderGeneration] = verification
        return true
    }

    /// Sends `new-window -P -F '#{window_id}'` and returns its stable window id.
    @discardableResult
    func sendNewWindow(_ command: String, completion: @escaping (Int?) -> Void) -> Bool {
        let token = UUID()
        newWindowCompletions[token] = completion
        guard sendInternal(command, kind: .newWindow(token)) else {
            newWindowCompletions.removeValue(forKey: token)?(nil)
            return false
        }
        return true
    }

    /// Sends `split-window -P -F '#{pane_id}'` and returns the stable pane id
    /// printed by that exact command block. Concurrent pane publications cannot
    /// be mistaken for the locally-created pane.
    @discardableResult
    func sendNewPane(_ command: String, completion: @escaping (Int?) -> Void) -> Bool {
        let token = UUID()
        newPaneCompletions[token] = completion
        guard sendInternal(command, kind: .newPane(token)) else {
            newPaneCompletions.removeValue(forKey: token)?(nil)
            return false
        }
        return true
    }

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        guard !windowListRequestInFlight else {
            windowListRequestDirty = true
            return
        }
        guard sendInternal(
            "list-windows -F \"#{window_id} #{window_layout} #{window_visible_layout} [#{window_flags}] #{window_name}\"",
            kind: .listWindows(
                reorderGeneration: windowReorderGeneration,
                retainedPaneIDs: paneIDsRetainedUntilWindowList
            )
        ) else { return }
        windowListRequestInFlight = true
    }

    func completeWindowListRequest() {
        windowListRequestInFlight = false
        guard windowListRequestDirty else { return }
        windowListRequestDirty = false
        requestWindows()
    }

    func resetWindowListRequestCoalescing() {
        windowListRequestInFlight = false
        windowListRequestDirty = false
    }

    func restartAfterWindowReorderRecoveryFailure() {
        record("window-reorder-recovery-reconnect")
        beginReconnecting()
    }

    /// Fetches one window's REAL pane rectangles (plus the active flag, the
    /// window's `pane-border-status`, and the pane's EXPANDED
    /// `pane-border-format` — exactly the header text a native tmux client
    /// would draw, custom formats included). The layout string is not ground
    /// truth: under `pane-border-status` tmux publishes the pre-title tree
    /// while panes touching the configured edge are shorter (and top-edge
    /// panes also sit lower). Placement must render where panes actually are,
    /// so a quarantined layout is published only by this fetch's reply. The
    /// expanded format is LAST (it
    /// may contain spaces) behind a `:` sentinel (it may expand to EMPTY,
    /// and a trailing empty field must survive line splitting).
    @discardableResult
    func requestPaneRects(windowId: Int, generation: Int) -> Bool {
        #if DEBUG
        cmuxDebugLog("remote.rects.request @\(windowId) gen=\(generation)")
        #endif
        let snapshotKey = RemoteTmuxPaneTitleSnapshotKey(windowId: windowId, generation: generation)
        paneTitleMetadataSnapshotRevisions[snapshotKey] = paneTitleMetadataRevision
        let sent = sendInternal(
            "list-panes -t @\(windowId) -F \"\(Self.paneRectsFormat)\"",
            kind: .paneRects(windowId, generation)
        )
        if !sent { paneTitleMetadataSnapshotRevisions[snapshotKey] = nil }
        return sent
    }

    /// Rearranges the tracked window order to reflect a just-applied reorder.
    /// `reordered` is the new sequence of a subset of windows (the ones the user
    /// dragged); windows not in it keep their slots. This is synchronous and exact
    /// — the `swap-window` commands achieve precisely this order, so it matches
    /// tmux without a round-trip, and a rapid follow-up reorder reads the
    /// just-applied order rather than a stale one. (A `list-windows` re-fetch would
    /// reintroduce the race: an earlier reorder's async snapshot could land after a
    /// later reorder and roll the order back. Out-of-band changes still reconcile
    /// via the topology events that already trigger ``requestWindows()``.)
    func applyWindowReorder(_ reordered: [Int]) {
        windowOrder = decoding.windowOrder(windowOrder, applyingReorder: reordered)
    }

    /// Captures a pane's current visible contents (with escapes) and delivers
    /// them to the pane-output observers so a freshly-mounted display surface shows
    /// the existing screen instead of starting blank.
    ///
    /// First queries `#{alternate_on}` and, if the remote pane is on the alternate
    /// screen, enters it on the mirror surface (emits `ESC[?1049h`) before the
    /// captured rows so they land on the matching screen and resize behaves like the
    /// remote (the alternate screen does not reflow).
    ///
    /// After the paint it restores terminal state the live `%output` doesn't carry
    /// (it set before cmux attached): scroll region, DEC private modes, the mouse
    /// tracking mode, and the cursor. Restoring the mouse mode means clicks, scroll,
    /// and drag in the mirror are forwarded to the remote app — so drag-to-select
    /// becomes the app's own selection/OSC 52 copy, and **Shift+drag** does a native
    /// cmux copy (exactly as a local terminal behaves with a mouse-mode app).
    @discardableResult
    func capturePane(paneId: Int, clearScrollback: Bool = false) -> UUID? {
        guard let seedID = beginPaneSeed(
            paneId: paneId,
            clearScrollback: clearScrollback,
            kind: .fullHistory
        ) else { return nil }
        // Keep this control client's pane output paused across the capture and
        // cursor-state query. The five commands are one tmux command queue, so
        // pane PTY reads cannot interleave between the authoritative snapshot,
        // its boundary cursor, and the continue edge. Transport chunking may
        // split the replies but cannot change their order.
        let outputPauseCommand = Self.paneOutputPauseCommand(paneId: paneId)
        // Match the remote pane's screen (primary vs alternate) BEFORE seeding the
        // captured rows. An alt-screen TUI (e.g. claude) must render on the mirror's
        // alternate screen so resize matches the remote (the alternate screen does
        // not reflow; the primary screen reflows/scrolls and offsets rows). The
        // pane was already on the alt screen before cmux attached, so its 1049h is
        // not in the live %output — query `#{alternate_on}` and enter alt ourselves.
        // Ordered first so the enter lands before the capture paint in the FIFO.
        let altScreenCommand = Self.paneAltScreenQueryCommand(paneId: paneId)
        // `-S -<N>` seeds scrollback history (not just the visible screen) so the
        // mirrored tab is scrollable immediately on attach/reconnect. On an
        // alternate-screen pane there is no history, so tmux clamps to the visible
        // alt screen — harmless.
        //
        // NOTE: do NOT add `-J` (join wrapped lines) here. It was tried to make a
        // shell pane's PRE-ATTACH scrollback rejoin cleanly on grow, but it rewrites
        // an inline/alt-screen TUI's captured rows into different logical lines, so
        // the seed paints shifted on reattach (claude's input line lands a row off
        // and the frame doubles) and scatters on resize. The reflow win for shells
        // comes from LIVE %output (which already carries real soft-wraps), not from
        // the seed — so `-J`'s only upside (pre-attach rejoin-on-grow) isn't worth
        // corrupting every TUI seed. Capture faithful visual rows instead.
        let captureCommand = "capture-pane -p -e -S -\(Self.scrollbackCaptureLines) -t %\(paneId)"
        // Query the pane's terminal STATE; tmux exposes it all as formats. Sent
        // after capture-pane so it applies on top of the painted rows (the seed
        // escapes are built in `paneStateSeedSequence`). See the doc comment for why
        // restoring this matters.
        guard sendCommandQueueInternal(
            [
                outputPauseCommand,
                altScreenCommand,
                captureCommand,
                Self.paneStateQueryCommand(paneId: paneId),
                Self.paneOutputContinueCommand(paneId: paneId),
            ],
            kinds: [
                .paneOutputReset(paneId, seedID),
                .paneAltScreen(paneId, seedID),
                .capturePane(paneId, seedID),
                .paneState(paneId, seedID),
                .paneOutputContinue(paneId, seedID),
            ]
        ) else {
            cancelPaneSeed(paneId: paneId, seedID: seedID)
            return nil
        }
        return seedID
    }

    /// Repaints ONE mirrored pane from tmux's current visible screen, for cells a
    /// grid grow just granted.
    ///
    /// tmux repaints only on change, so cells granted after tmux already streamed
    /// their rows hold nothing: the surface clipped that content while its grid was
    /// short. tmux's own grid HAS the rows — only the mirror lost them — so the
    /// repair is to read tmux's screen, not to make tmux or the remote re-render.
    /// That is why this replaces the shrink→restore size kick here: the kick forced
    /// a SIGWINCH by moving the CLIENT size, which made tmux re-round an odd split
    /// and hand a stacked pane a different row count, which grew a pane again and
    /// re-fired the kick — an unbounded loop (23k kicks in one fuzz iteration).
    /// `capture-pane` and `display-message` are reads: no client size moves and
    /// tmux re-rounds nothing. Every genuine grow therefore requests this repair;
    /// grows observed while a seed is in flight coalesce into one follow-up so a
    /// slow control channel cannot accumulate repaint transactions without bound.
    ///
    /// No `-S`: the seed's scrollback history is already in the surface, and
    /// re-emitting it would stack a second copy into the mirror's scrollback. The
    /// visible screen is exactly what a clipped grow lost. The reply paints
    /// home+clear+rows (see the `.capturePane` result), so this REPLACES the
    /// visible screen rather than appending, and the `.paneState` seed that follows
    /// restores the cursor and scroll region on top. The alternate-screen query
    /// also precedes the capture so a TUI transition during a slow repaint cannot
    /// paint the authoritative rows onto the mirror's stale screen.
    @discardableResult
    func repaintPaneVisibleScreen(paneId: Int) -> UUID? {
        guard pendingPaneVisibleRepaintSeedIDs[paneId] == nil else {
            deferredPaneVisibleRepaints.insert(paneId)
            return nil
        }
        let gatesReconnectReady = pendingPaneSeeds[paneId]?.contains {
            pendingReconnectSeedIDs.contains($0.id)
        } == true
        guard let seedID = beginPaneSeed(
            paneId: paneId,
            clearScrollback: false,
            kind: .visibleRepaint
        ) else {
            return nil
        }
        guard sendCommandQueueInternal(
            [
                Self.paneOutputPauseCommand(paneId: paneId),
                Self.paneAltScreenQueryCommand(paneId: paneId),
                "capture-pane -p -e -t %\(paneId)",
                Self.paneStateQueryCommand(paneId: paneId),
                Self.paneOutputContinueCommand(paneId: paneId),
            ],
            kinds: [
                .paneOutputReset(paneId, seedID),
                .paneAltScreen(paneId, seedID),
                .capturePane(paneId, seedID),
                .paneState(paneId, seedID),
                .paneOutputContinue(paneId, seedID),
            ]
        ) else {
            cancelPaneSeed(paneId: paneId, seedID: seedID)
            return nil
        }
        pendingPaneVisibleRepaintSeedIDs[paneId] = seedID
        if gatesReconnectReady { pendingReconnectSeedIDs.insert(seedID) }
        return seedID
    }

    /// Pauses and discards queued output for one pane on this control client.
    static func paneOutputPauseCommand(paneId: Int) -> String {
        // tmux parses an unquoted `%pane:state` token as syntax, before -A sees it.
        "refresh-client -A \"%\(paneId):pause\""
    }

    /// Resumes pane output after the same command queue captured screen and state.
    static func paneOutputContinueCommand(paneId: Int) -> String {
        "refresh-client -A \"%\(paneId):continue\""
    }

    /// The `display-message` line that reads whether a pane uses the alternate screen.
    static func paneAltScreenQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"#{alternate_on}\""
    }

    /// The `display-message` line that reads a pane's terminal state (cursor,
    /// scroll region, DEC modes) for the `.paneState` seed. Shared by the attach
    /// seed and ``repaintPaneVisibleScreen(paneId:)`` so the two cannot drift.
    static func paneStateQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \""
            + "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
            + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
            + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
            + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
            + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_height=#{pane_height},"
            + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
            + "mouse_standard_flag=#{mouse_standard_flag},"
            + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag}\""
    }

    /// Seeds (or re-seeds) a mirrored pane in the one canonical sequence: reflow
    /// classification FIRST (the one-shot query — always works — then the live
    /// subscription for re-classification, e.g. bash → node), then the content
    /// capture, then cwd tracking (initial value + live `cd`). Classification is
    /// queued before the five-command capture because it only matters at the next
    /// resize — the earlier it lands, the smaller the window in which a resize
    /// hits the conservative no-reflow default on a slow link.
    @discardableResult
    func seedPane(paneId: Int, clearScrollback: Bool = true) -> UUID? {
        requestPaneReflow(paneId: paneId)
        let seedID = capturePane(paneId: paneId, clearScrollback: clearScrollback)
        requestPanePath(paneId: paneId)
        // One batched refresh-client for all four live subscriptions
        // instead of four separate sends — see subscribePaneAll. Under
        // churn this is the difference between the command FIFO keeping up
        // with tmux and backing up into minutes-long non-convergence.
        subscribePaneAll(paneId: paneId)
        return seedID
    }

    /// Replays this control client's recorded sizing authority after an event
    /// that may have changed tmux's effective minimum. Reconnect needs this
    /// because a fresh client has no claims; peer detach needs it because tmux
    /// does not otherwise ask surviving clients to resend their desired sizes.
    func replayRecordedSizeClaims() {
        // Reset the dedup baseline before replay, or claims matching prior sends
        // would be suppressed even though tmux may need to recompute them.
        sentWindowSizes.removeAll()
        // Open a fresh parity episode for every replayed claim. A budget spent
        // while a smaller peer legitimately clamped the window must not suppress
        // recovery after that peer leaves.
        windowClaimParityRearmsSpent.removeAll()
        if let size = lastClientSize {
            send("refresh-client -C \(size.columns)x\(size.rows)")
        }
        if supportsPerWindowSize {
            for (windowId, size) in lastWindowSizes.sorted(by: { $0.key < $1.key }) {
                sendPerWindowSize(windowId: windowId, columns: size.0, rows: size.1)
            }
        }
    }

    func reseedAfterReconnect() {
        replayRecordedSizeClaims()
        // The border-status watches were dropped at `beginReconnecting()` — before
        // this reseed's own list-windows restage, which is what re-issues them.
        // Clearing them here would be too late: the restage has already run.
        pendingReconnectSeedIDs.removeAll(keepingCapacity: true)
        var seenPaneIDs: Set<Int> = []
        pendingReconnectPaneIDs = windowsByID.keys.sorted().flatMap { windowId in
            (windowsByID[windowId]?.paneIDsInOrder ?? []).filter {
                seenPaneIDs.insert($0).inserted
            }
        }
        pumpReconnectPaneSeeds()
        // A batch rejection synchronously begins another reconnect and discards
        // its seeds. Never resurrect those IDs or announce readiness for the dead
        // stream after the loop returns.
        guard connectionState == .connected else { return }
        notifyReconnectReadyIfSeedBatchDrained()
    }

    /// Sends literal key bytes to a pane via tmux `send-keys -H` (hex-encoded),
    /// which is binary-safe and needs no shell quoting.
    @discardableResult
    func sendKeys(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let hex = Self.hexByteArguments(data)
        return sendInternal("send-keys -t %\(paneId) -H \(hex)", kind: .other)
    }

    /// Sends a physical named key and lets tmux encode it for the target pane's
    /// advertised terminal and live input modes.
    @discardableResult
    func sendKey(paneId: Int, key: RemoteTmuxKeyName) -> Bool {
        sendInternal("send-keys -t %\(paneId) \(key.value)", kind: .other)
    }

    nonisolated static func hexByteArguments(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Pastes `text` into `paneId` as a tmux paste (`paste-buffer -p`), which wraps
    /// the content in bracketed-paste markers IFF the real pane's app has
    /// bracketed-paste mode enabled — tmux tracks that on the real pty, which the
    /// mirror surface can't see. This makes a pasted/dropped image path arrive as a
    /// genuine paste, so the remote app recognizes it (e.g. claude → `[Image #N]`)
    /// instead of seeing the plain keystrokes that ``sendKeys(paneId:data:)`` would
    /// deliver. Uses a dedicated, immediately-deleted (`-d`) per-pane buffer so
    /// there's no buffer-name collision. `text` must be a single line (callers route
    /// only single-line content — e.g. file/image paths — here).
    func pastePane(paneId: Int, text: String) -> Bool {
        guard let commands = Self.pastePaneCommands(paneId: paneId, text: text) else { return false }
        return send(commands.setBuffer) && send(commands.pasteBuffer)
    }

    nonisolated static func pastePaneCommands(paneId: Int, text: String)
        -> (setBuffer: String, pasteBuffer: String)?
    {
        guard !text.isEmpty else { return nil }
        let buffer = "cmux-paste-\(paneId)"
        return (
            setBuffer: "set-buffer -b \(buffer) -- \(RemoteTmuxHost.shellSingleQuoted(text))",
            pasteBuffer: "paste-buffer -p -d -b \(buffer) -t %\(paneId)"
        )
    }
}
