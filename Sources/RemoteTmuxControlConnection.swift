import Foundation

/// A live tmux control-mode connection to one remote session.
///
/// Spawns `ssh -tt <ControlMaster> host tmux -CC attach -t <session>` as a
/// `Process` with pipes, feeds its stdout through ``RemoteTmuxControlStreamParser``
/// (in order, via an `AsyncStream`), and exposes the mirrored topology plus a
/// live output callback. cmux owns the whole protocol here — so it never depends
/// on ghostty's (tmux-3.6-fragile) built-in Viewer, and there is no
/// command-queue desync because we issue and correlate commands ourselves.
@MainActor
final class RemoteTmuxControlConnection {
    /// The host this connection talks to.
    let host: RemoteTmuxHost
    /// The tmux session name this connection attaches to. Mutable because a
    /// `rename-session` changes it (the underlying `$id` is stable).
    private(set) var sessionName: String

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    /// Opaque token identifying a registered observer (pass to ``removeObserver(_:)``).
    typealias ObserverToken = UUID

    // Multicast observer registries. A single connection is shared by every
    // consumer of the same host+session (``RemoteTmuxController.attach`` reuses
    // it), so events MUST fan out to all consumers — a single overwritable
    // closure silently cut off whichever consumer wired up first.
    private var paneOutputObservers: [ObserverToken: (_ paneId: Int, _ data: Data) -> Void] = [:]
    private var paneCwdObservers: [ObserverToken: (_ paneId: Int, _ path: String) -> Void] = [:]
    private var activePaneObservers: [ObserverToken: (_ windowId: Int, _ paneId: Int) -> Void] = [:]
    private var topologyObservers: [ObserverToken: () -> Void] = [:]
    private var exitObservers: [ObserverToken: () -> Void] = [:]

    // MARK: Observed state

    private(set) var started = false
    private(set) var enterReceived = false
    private(set) var exited = false
    private(set) var sessionId: Int?
    private(set) var windowsByID: [Int: RemoteTmuxWindow] = [:]
    private(set) var windowOrder: [Int] = []
    private(set) var activePaneByWindow: [Int: Int] = [:]
    private(set) var paneOutputByteCounts: [Int: Int] = [:]
    private(set) var totalOutputBytes = 0
    private(set) var recentEvents: [String] = []

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReader: FileHandle?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var parser = RemoteTmuxControlStreamParser()
    private var ingestTask: Task<Void, Never>?
    private var pendingCommands: [CommandKind] = []
    private let createIfMissing: Bool
    private let maxRecentEvents = 100

    private enum CommandKind: Equatable {
        case listWindows, capturePane(Int), paneCursor(Int), panePath(Int), other
    }

    /// Subscription-name prefix for per-pane `pane_current_path` (`refresh-client -B`).
    /// The tmux pane id is appended so an inbound `%subscription-changed` can be
    /// routed back to its pane; defined once so the writer and reader can't drift.
    private static let cwdSubscriptionPrefix = "cmux_cwd_"

    init(host: RemoteTmuxHost, sessionName: String, createIfMissing: Bool = false) {
        self.host = host
        self.sessionName = sessionName
        self.createIfMissing = createIfMissing
    }

    // MARK: - Observers

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple consumers (e.g. a mirrored workspace and a single-pane display
    /// tab) can observe the same shared connection concurrently; every callback
    /// fires for every event. Pass the returned token to ``removeObserver(_:)``
    /// when the consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes (see ``requestPanePath(paneId:)``
    ///     and ``subscribePanePath(paneId:)``).
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onExit: fires once when control mode ends.
    @discardableResult
    func addObserver(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil
    ) -> ObserverToken {
        let token = ObserverToken()
        if let onPaneOutput { paneOutputObservers[token] = onPaneOutput }
        if let onPaneCwd { paneCwdObservers[token] = onPaneCwd }
        if let onActivePaneChanged { activePaneObservers[token] = onActivePaneChanged }
        if let onTopologyChanged { topologyObservers[token] = onTopologyChanged }
        if let onExit { exitObservers[token] = onExit }
        return token
    }

    /// Deregisters the callbacks registered under `token`.
    func removeObserver(_ token: ObserverToken) {
        paneOutputObservers[token] = nil
        paneCwdObservers[token] = nil
        activePaneObservers[token] = nil
        topologyObservers[token] = nil
        exitObservers[token] = nil
    }

    private func emitPaneOutput(_ paneId: Int, _ data: Data) {
        for callback in paneOutputObservers.values { callback(paneId, data) }
    }

    private func emitPaneCwd(_ paneId: Int, _ path: String) {
        for callback in paneCwdObservers.values { callback(paneId, path) }
    }

    private func emitActivePaneChanged(_ windowId: Int, _ paneId: Int) {
        for callback in activePaneObservers.values { callback(windowId, paneId) }
    }

    private func notifyTopologyChanged() {
        for callback in topologyObservers.values { callback() }
    }

    private func notifyExit() {
        for callback in exitObservers.values { callback() }
    }

    /// Spawns the SSH `tmux -CC` process and begins streaming.
    func start() throws {
        guard !started else { return }
        try host.ensureControlSocketDirectory()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = host.controlModeArguments(
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        proc.terminationHandler = { _ in continuation.finish() }

        do {
            try proc.run()
        } catch {
            // Don't latch `started` on a failed launch, so a later attach can
            // replace this connection instead of reusing a dead one. Close the
            // stdin handle too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            reader.readabilityHandler = nil
            continuation.finish()
            try? stdinHandle?.close()
            stdinHandle = nil
            throw error
        }
        started = true
        process = proc
        stdoutReader = reader
        streamContinuation = continuation
        ingestTask = Task { [weak self] in
            for await chunk in stream {
                self?.ingest(chunk)
            }
            self?.handleStreamEnd()
        }
    }

    /// Sends a tmux command on the control stream (newline-terminated).
    func send(_ command: String) {
        sendInternal(command, kind: .other)
    }

    /// Sizes the tmux control client to `columns`×`rows` cells (tmux
    /// `refresh-client -C`) so the remote windows/panes reflow to the rendered
    /// cmux grid. Without this a freshly attached session stays at ssh's default
    /// 80×24 and TUIs (claude, claude agents) render mangled. No-ops once the
    /// connection has exited or for a degenerate grid.
    ///
    /// This is the single sizing entrypoint every remote-tmux render path routes
    /// through (the single-pane display surface and the multi-pane window mirror),
    /// so client sizing stays one shared behavior rather than duplicated sends.
    func setClientSize(columns: Int, rows: Int) {
        guard !exited, columns > 0, rows > 0 else { return }
        send("refresh-client -C \(columns)x\(rows)")
    }

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        sendInternal(
            "list-windows -F \"#{window_id} #{window_layout} #{window_name}\"",
            kind: .listWindows
        )
    }

    /// Captures a pane's current visible contents (with escapes) and delivers
    /// them to the pane-output observers so a freshly-mounted display surface shows
    /// the existing screen instead of starting blank.
    func capturePane(paneId: Int) {
        sendInternal("capture-pane -p -e -t %\(paneId)", kind: .capturePane(paneId))
        // Follow with the real cursor position so the surface cursor lines up
        // with tmux's prompt (capture-pane alone doesn't carry the cursor).
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{cursor_x},#{cursor_y}\"",
            kind: .paneCursor(paneId)
        )
    }

    /// One-shot query of a pane's working directory (`pane_current_path`),
    /// delivered to the cwd observers. Guarantees an initial folder for the
    /// mirrored tab even on tmux builds without control-mode subscriptions.
    func requestPanePath(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{pane_current_path}\"",
            kind: .panePath(paneId)
        )
    }

    /// Subscribes to live `pane_current_path` changes for `paneId` via tmux
    /// control-mode `refresh-client -B`, so a remote `cd` updates the mirrored
    /// tab's folder without polling. tmux emits the value once on subscribe and
    /// again on every change as `%subscription-changed cmux_cwd_<paneId> … : <path>`.
    /// Best-effort: on tmux builds that don't support subscriptions the command is
    /// a no-op and ``requestPanePath(paneId:)`` still supplies the initial folder.
    func subscribePanePath(paneId: Int) {
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId):%\(paneId):#{pane_current_path}")
    }

    /// Removes the live `pane_current_path` subscription for `paneId` (issued once
    /// the pane is gone). tmux also drops a dead pane's subscriptions on its own;
    /// this keeps the client's subscription set tidy across split/close churn.
    func unsubscribePanePath(paneId: Int) {
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId)")
    }

    /// Sends literal key bytes to a pane via tmux `send-keys -H` (hex-encoded),
    /// which is binary-safe and needs no shell quoting.
    func sendKeys(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendInternal("send-keys -t %\(paneId) -H \(hex)", kind: .other)
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
    func pastePane(paneId: Int, text: String) {
        guard !text.isEmpty else { return }
        let buffer = "cmux-paste-\(paneId)"
        send("set-buffer -b \(buffer) \(RemoteTmuxHost.shellSingleQuoted(text))")
        send("paste-buffer -p -d -b \(buffer) -t %\(paneId)")
    }

    /// Detaches: terminating ssh kills the control client but leaves the remote
    /// tmux session alive for resume.
    func stop() {
        // Mark exited FIRST so the deliberate teardown does not fire `onExit`:
        // finishing the stream makes the ingest task run `handleStreamEnd`, whose
        // `guard !exited` then short-circuits. Only a genuine remote end (a real
        // `%exit`, an unexpected stream EOF, or a broken-pipe write) notifies exit
        // observers — so detach/quit/window-close (preserve) never trigger the
        // "session ended remotely" cleanup.
        exited = true
        ingestTask?.cancel()
        ingestTask = nil
        process?.terminationHandler = nil
        // Tear down the stdout reader deterministically rather than waiting for
        // EOF (the ingest consumer is already cancelled).
        stdoutReader?.readabilityHandler = nil
        stdoutReader = nil
        streamContinuation?.finish()
        streamContinuation = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    private func sendInternal(_ command: String, kind: CommandKind) {
        guard let stdinHandle else { return }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            // The control pipe is dead (broken pipe). Crucially, do NOT enqueue
            // a pending command for a write that never reached tmux: the
            // %begin/%end correlation FIFO is positional, so one phantom entry
            // permanently misaligns every subsequent command result. Tear the
            // connection down instead and let observers reconnect.
            record("stdin-write-failed")
            handleWriteFailure()
            return
        }
        // Record only after the bytes are confirmed written, so the pending
        // FIFO stays in lock-step with what tmux actually received.
        pendingCommands.append(kind)
    }

    private func handleWriteFailure() {
        guard !exited else { return }
        exited = true
        stop()
        notifyExit()
    }

    private func ingest(_ data: Data) {
        for message in parser.feed(data) {
            handle(message)
        }
    }

    private func handleStreamEnd() {
        guard !exited else { return }
        exited = true
        record("stream-end")
        notifyExit()
    }

    private func handle(_ message: RemoteTmuxControlMessage) {
        switch message {
        case .enter:
            enterReceived = true
            record("enter")
        case let .exit(reason):
            exited = true
            record("exit\(reason.map { " " + $0 } ?? "")")
            notifyExit()
        case let .output(paneId, data):
            paneOutputByteCounts[paneId, default: 0] += data.count
            totalOutputBytes += data.count
            emitPaneOutput(paneId, data)
        case let .sessionChanged(id, _):
            sessionId = id
            record("session-changed $\(id)")
            requestWindows()
        case .sessionsChanged:
            record("sessions-changed")
        case let .windowAdd(id):
            record("window-add @\(id)")
            requestWindows()
        case let .windowClose(id):
            // Release the closed window's per-pane/per-window diagnostic state so
            // it doesn't accumulate across window churn.
            if let closing = windowsByID[id] {
                for pane in closing.paneIDsInOrder { paneOutputByteCounts[pane] = nil }
            }
            activePaneByWindow[id] = nil
            windowsByID[id] = nil
            windowOrder.removeAll { $0 == id }
            record("window-close @\(id)")
            notifyTopologyChanged()
        case let .windowRenamed(id, name):
            record("window-renamed @\(id)")
            // Propagate the new name into the topology so the mirrored tab title
            // refreshes. Keep the existing geometry/layout.
            if let existing = windowsByID[id], existing.name != name {
                windowsByID[id] = RemoteTmuxWindow(
                    id: id, name: name,
                    width: existing.width, height: existing.height, layout: existing.layout
                )
                notifyTopologyChanged()
            }
        case let .layoutChange(id, layout):
            applyLayout(windowId: id, layout: layout)
            record("layout-change @\(id)")
            notifyTopologyChanged()
        case let .windowPaneChanged(windowId, paneId):
            activePaneByWindow[windowId] = paneId
            emitActivePaneChanged(windowId, paneId)
        case let .sessionWindowChanged(_, windowId):
            record("session-window-changed @\(windowId)")
        case let .subscriptionChanged(name, value):
            // cmux subscribes each pane's working directory as "cmux_cwd_<paneId>".
            if name.hasPrefix(Self.cwdSubscriptionPrefix),
               let paneId = Int(name.dropFirst(Self.cwdSubscriptionPrefix.count)) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { emitPaneCwd(paneId, path) }
            }
        case let .commandResult(_, lines, isError):
            handleCommandResult(lines: lines, isError: isError)
        case .ignoredNotification, .unparsed:
            break
        }
    }

    private func handleCommandResult(lines: [String], isError: Bool) {
        // The attach command's own block arrives before we queue anything; only
        // correlate results once we have an outstanding command.
        guard !pendingCommands.isEmpty else { return }
        let kind = pendingCommands.removeFirst()
        guard !isError else { return }
        switch kind {
        case .listWindows:
            var order: [Int] = []
            for line in lines {
                // "@<id> <layout> <name with spaces…>" — id and layout never
                // contain spaces, so split into at most 3 fields.
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 2,
                      let id = RemoteTmuxControlStreamParser.id(parts[0], sigil: "@"),
                      let node = RemoteTmuxRawLayoutParser.parse(String(parts[1]))
                else { continue }
                let name = parts.count >= 3 ? String(parts[2]) : ""
                windowsByID[id] = RemoteTmuxWindow(
                    id: id, name: name, width: node.width, height: node.height, layout: node
                )
                order.append(id)
            }
            if !order.isEmpty {
                windowOrder = order
                notifyTopologyChanged()
            }
        case let .capturePane(paneId):
            // capture-pane -e output is the pane's visible rows (with SGR
            // escapes). Home + clear, paint the rows, and leave the cursor at
            // the END of the last row (no trailing newline) so it lines up with
            // tmux's real prompt cursor — otherwise echoed input lands a line
            // below the prompt.
            let painted = "\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
            if let data = painted.data(using: .utf8) {
                emitPaneOutput(paneId, data)
            }
        case let .paneCursor(paneId):
            // "x,y" (0-based) → absolute cursor-position escape so the surface
            // cursor matches tmux's, even though capture-pane trims trailing
            // spaces from the painted prompt line.
            if let line = lines.first {
                let parts = line.split(separator: ",")
                if parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]),
                   let data = "\u{1b}[\(y + 1);\(x + 1)H".data(using: .utf8) {
                    emitPaneOutput(paneId, data)
                }
            }
        case let .panePath(paneId):
            if let path = lines.first?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                emitPaneCwd(paneId, path)
            }
        case .other:
            break
        }
    }

    private func applyLayout(windowId: Int, layout: String) {
        guard let node = RemoteTmuxRawLayoutParser.parse(layout) else { return }
        // Preserve any name tmux already reported (a %layout-change carries no name).
        let existingName = windowsByID[windowId]?.name ?? ""
        windowsByID[windowId] = RemoteTmuxWindow(
            id: windowId, name: existingName, width: node.width, height: node.height, layout: node
        )
        if !windowOrder.contains(windowId) { windowOrder.append(windowId) }
    }

    private func record(_ event: String) {
        recentEvents.append(event)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }
    }

    /// An immutable, `Sendable` snapshot for diagnostics (`remote.tmux.state`).
    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            enterReceived: enterReceived,
            exited: exited,
            sessionId: sessionId,
            windowCount: windowsByID.count,
            windowIDs: windowOrder,
            paneOutputByteCounts: paneOutputByteCounts,
            totalOutputBytes: totalOutputBytes,
            recentEvents: recentEvents
        )
    }

    struct Snapshot: Sendable {
        let started: Bool
        let enterReceived: Bool
        let exited: Bool
        let sessionId: Int?
        let windowCount: Int
        let windowIDs: [Int]
        let paneOutputByteCounts: [Int: Int]
        let totalOutputBytes: Int
        let recentEvents: [String]
    }
}
