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

    /// Asks tmux to answer, so a stalled-but-alive transport can be told from a healthy one.
    ///
    /// This is the liveness check a transport that owns its own reconnection needs. cmux's
    /// recovery is built on stdout EOF, but such a transport produces no EOF for a network
    /// drop — the stream pauses and resumes — so EOF cannot be the trigger and a stall must
    /// not be mistaken for death. What is left is asking the far end a question:
    ///
    /// - the process is still alive, and
    /// - a control-mode round-trip completes.
    ///
    /// `display-message -p` is the cheapest question that proves both. It is a read, so it
    /// moves no client size and mutates nothing, and it resolves through the same
    /// `%begin`/`%end` correlation as any other command — which is why this reuses
    /// ``sendTracked(_:completion:)`` rather than inventing a heartbeat with its own timer
    /// and its own failure modes.
    ///
    /// - Parameter completion: `true` when tmux answered, `false` when the block resolved as
    ///   an error or the stream reset before answering. Not called at all if the command
    ///   could not be enqueued, which the `false` return reports.
    @discardableResult
    func probeLiveness(completion: @escaping (Bool) -> Void) -> Bool {
        guard !exited else { return false }
        return sendTracked("display-message -p cmux-liveness", completion: completion)
    }

    /// Checks a stalled-but-alive control stream and recovers it.
    ///
    /// A transport that reconnects internally never delivers the EOF that drives ssh recovery:
    /// during a network change its process stays up and the stream simply pauses. That is the
    /// behavior worth having, but it means a transport that is alive and *not* recovering looks
    /// exactly like one that is idle. Nothing else in the lifecycle can tell those apart, so
    /// without this check a wedged et connection stays `.connected` forever and the mirror
    /// freezes with no error and no retry.
    ///
    /// A silent stream alone does not say which of those two it is. A real network interruption
    /// silences the stream too, and the transport cannot answer a probe while it is reconnecting
    /// underneath — so treating silence as the verdict kills the process and throws away the
    /// session it was in the middle of recovering. The unanswered probe is therefore a suspicion,
    /// and the question that settles it is asked somewhere else: ``sessionReachability`` runs a
    /// one-shot over ssh's shared master, a channel this stream's wedge cannot affect. A host that
    /// answers there proves the network is fine and the stream is the broken part, which is the
    /// case to recover. A host that does not answer is an outage, and an outage is what this
    /// transport exists to ride out — so stay `.connected` and ask again next tick, bounded by
    /// ``maxConsecutiveLivenessDeferrals`` so a host that is both unreachable and wedged still
    /// gets its reconnect.
    ///
    /// Only reachable for `reconnectsInternally` transports: ssh gets its EOF and must keep its
    /// existing behavior exactly, including staying quiet on an idle stream.
    ///
    /// - Parameter completion: `true` if the stream answered, the check did not apply, or the
    ///   verdict was deferred; `false` if the stream was found wedged and recovery was started.
    ///   A deferral reports `true` because `false` means "recovery has started" — callers act on
    ///   that edge, and a deferral deliberately starts nothing.
    func checkLivenessAndRecoverIfStalled(completion: ((Bool) -> Void)? = nil) {
        guard transportProfile.reconnectsInternally, connectionState == .connected, !exited else {
            completion?(true)
            return
        }
        let generation = processGeneration
        // A previous probe left unanswered is the suspected stall. ET can accept stdin while
        // producing no control output, so a probe can be written and simply never answered —
        // without this the probes accumulate, every one of them still pending, and the connection
        // sits `.connected` forever. The deadline is the next tick rather than a second timer:
        // probe N must be answered before probe N+1 is due, which is a generous bound on a local
        // round-trip and needs no clock of its own.
        if livenessProbeOutstanding {
            record("liveness-unanswered")
            resolveSuspectedStall(generation: generation, completion: completion)
            return
        }
        livenessProbeOutstanding = true
        // A probe that cannot even be enqueued means the stream is already unusable.
        let enqueued = probeLiveness { [weak self] answered in
            self?.livenessProbeOutstanding = false
            guard let self else { return }
            guard generation == self.processGeneration else {
                // A respawn overtook this probe; its answer says nothing about the live stream.
                completion?(true)
                return
            }
            if answered {
                // The stream is carrying the protocol, so any run of deferred ticks is over.
                self.livenessDeferralCount = 0
                completion?(true)
            } else {
                self.recoverFromStalledTransport()
                completion?(false)
            }
        }
        if !enqueued {
            livenessProbeOutstanding = false
            recoverFromStalledTransport()
            completion?(false)
        }
    }

    /// Asks out of band whether the far end is reachable, then either recovers the stream or
    /// defers the verdict to the next tick. See ``checkLivenessAndRecoverIfStalled(completion:)``
    /// for why the silent stream cannot answer this itself.
    private func resolveSuspectedStall(generation: UInt64, completion: ((Bool) -> Void)?) {
        // One query at a time. The one-shot bounds itself with ssh's `ConnectTimeout` and
        // `ServerAlive*` rather than a deadline of its own, so on a dead network it can outlast a
        // tick; a second query would ask about the same outage and could recover twice for one
        // stall. Report `true` — this tick found nothing wedged, and the query already running is
        // the one that decides.
        guard !livenessReachabilityQueryInFlight else {
            completion?(true)
            return
        }
        livenessReachabilityQueryInFlight = true
        // Read the session name now: a `rename-session` during the query would otherwise change
        // which session the answer is about.
        let reachability = sessionReachability
        let host = self.host
        let sessionName = self.sessionName
        Task { @MainActor [weak self] in
            let reachable = await reachability(host, sessionName)
            guard let self else { return }
            self.livenessReachabilityQueryInFlight = false
            // A respawn overtook the query: the stream this answer describes is gone, so acting on
            // it would recover a stream that was already replaced.
            guard generation == self.processGeneration, self.connectionState == .connected else {
                completion?(true)
                return
            }
            // The probe came back while the query was out. The stream is answering after all, so
            // there is nothing to recover regardless of what the host said.
            guard self.livenessProbeOutstanding else {
                completion?(true)
                return
            }
            if reachable {
                self.recoverFromStalledTransport()
                completion?(false)
                return
            }
            self.livenessDeferralCount += 1
            if self.livenessDeferralCount > Self.maxConsecutiveLivenessDeferrals {
                // Long enough. Either the outage is not what is keeping the stream quiet, or it
                // has lasted past anything this transport is going to recover from on its own.
                self.record("liveness-deferral-exhausted")
                self.recoverFromStalledTransport()
                completion?(false)
                return
            }
            self.record("liveness-deferred-unreachable")
            completion?(true)
        }
    }

    /// Clears the probe bookkeeping so a fresh stream is judged on its own evidence.
    ///
    /// Leaves ``livenessReachabilityQueryInFlight`` alone deliberately: a query that is still
    /// running clears that itself when it lands, and clearing it here would let a second query
    /// start while the first is outstanding.
    func resetLivenessProbeState() {
        livenessProbeOutstanding = false
        livenessDeferralCount = 0
    }

    /// Replaces a transport that is alive but no longer carrying the protocol.
    ///
    /// Recovery is a respawn rather than an end: the remote session is very likely still there —
    /// it is the client that is wedged — so the mirror should be reconnected, not torn down. This
    /// routes through the same `beginReconnecting()` path as an ssh transport loss so there is one
    /// reconnect implementation rather than a second one for this case.
    private func recoverFromStalledTransport() {
        guard connectionState == .connected else { return }
        record("liveness-stalled")
        beginReconnecting()
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
        return sendInternal(
            "list-panes -t @\(windowId) -F \"#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active} #{pane-border-status} :#{T:pane-border-format}\"",
            kind: .paneRects(windowId, generation)
        )
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
        // One batched refresh-client for all three live subscriptions
        // instead of three separate sends — see subscribePaneAll. Under
        // churn this is the difference between the command FIFO keeping up
        // with tmux and backing up into minutes-long non-convergence.
        subscribePaneAll(paneId: paneId)
        return seedID
    }

    func reseedAfterReconnect() {
        // The fresh ssh client has been sent nothing: the dedup baseline
        // must reset with it, or requests matching pre-drop sends would be
        // suppressed against a server that no longer has them.
        sentWindowSizes.removeAll()
        // Parity episodes are per connection too: a re-arm budget spent
        // against the old transport must not suppress re-arms when this
        // reseed's own resends get lost or raced the same way.
        windowClaimParityRearmsSpent.removeAll()
        // The border-status watches were dropped at `beginReconnecting()` — before
        // this reseed's own list-windows restage, which is what re-issues them.
        // Clearing them here would be too late: the restage has already run.
        if let size = lastClientSize {
            send("refresh-client -C \(size.columns)x\(size.rows)")
        }
        // Re-pin every per-window size: pins are per-client state, and the
        // fresh ssh client starts with none (windows would sit at 80×24 or
        // the session-wide size). Feed-forward by nature — replays recorded
        // requests, reads nothing back.
        if supportsPerWindowSize {
            for (windowId, size) in lastWindowSizes.sorted(by: { $0.key < $1.key }) {
                sendPerWindowSize(windowId: windowId, columns: size.0, rows: size.1)
            }
        }
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
