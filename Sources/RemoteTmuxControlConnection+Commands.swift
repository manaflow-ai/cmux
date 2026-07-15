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
    func capturePane(paneId: Int) {
        // Match the remote pane's screen (primary vs alternate) BEFORE seeding the
        // captured rows. An alt-screen TUI (e.g. claude) must render on the mirror's
        // alternate screen so resize matches the remote (the alternate screen does
        // not reflow; the primary screen reflows/scrolls and offsets rows). The
        // pane was already on the alt screen before cmux attached, so its 1049h is
        // not in the live %output — query `#{alternate_on}` and enter alt ourselves.
        // Ordered first so the enter lands before the capture paint in the FIFO.
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{alternate_on}\"",
            kind: .paneAltScreen(paneId)
        )
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
        sendInternal("capture-pane -p -e -S -\(Self.scrollbackCaptureLines) -t %\(paneId)", kind: .capturePane(paneId))
        // Query the pane's terminal STATE; tmux exposes it all as formats. Sent
        // after capture-pane so it applies on top of the painted rows (the seed
        // escapes are built in `paneStateSeedSequence`). See the doc comment for why
        // restoring this matters.
        sendInternal(Self.paneStateQueryCommand(paneId: paneId), kind: .paneState(paneId))
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
    /// `capture-pane` and `display-message` are reads: no client size moves, tmux
    /// re-rounds nothing, so this can fire on EVERY genuine grow with no loop and
    /// no need to ration it.
    ///
    /// No `-S`: the seed's scrollback history is already in the surface, and
    /// re-emitting it would stack a second copy into the mirror's scrollback. The
    /// visible screen is exactly what a clipped grow lost. The reply paints
    /// home+clear+rows (see the `.capturePane` result), so this REPLACES the
    /// visible screen rather than appending, and the `.paneState` seed that follows
    /// restores the cursor and scroll region on top.
    func repaintPaneVisibleScreen(paneId: Int) {
        sendInternal("capture-pane -p -e -t %\(paneId)", kind: .capturePane(paneId))
        sendInternal(Self.paneStateQueryCommand(paneId: paneId), kind: .paneState(paneId))
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
    /// queued before the (3-command) capture because it only matters at the next
    /// resize — the earlier it lands, the smaller the window in which a resize
    /// hits the conservative no-reflow default on a slow link.
    func seedPane(paneId: Int) {
        requestPaneReflow(paneId: paneId)
        capturePane(paneId: paneId)
        requestPanePath(paneId: paneId)
        // One batched refresh-client for all three live subscriptions
        // instead of three separate sends — see subscribePaneAll. Under
        // churn this is the difference between the command FIFO keeping up
        // with tmux and backing up into minutes-long non-convergence.
        subscribePaneAll(paneId: paneId)
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
        // The re-applied size is usually a no-op (the server kept the window at our
        // size across the transport drop), so TUIs get no SIGWINCH — kick them so
        // they repaint over the re-seeded (possibly stale) frame. FIFO-safe: the
        // captures below are queued before the kick task's first push can run.
        scheduleAttachRedrawKickIfNeeded()
        for window in windowsByID.values {
            for paneId in window.paneIDsInOrder {
                observers.emitPaneOutput(paneId, Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
                seedPane(paneId: paneId)
            }
        }
        observers.notifyReconnectReady()
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
