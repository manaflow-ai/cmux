import Foundation

/// Pure orchestration for a local tmux control-mode session, with no process
/// or threading. It turns gateway input + caller intents into a list of
/// ``Effect`` values (bytes to write to the gateway, snapshot/output to feed
/// the surface, end-of-session). The Process- and queue-bound wrapper lives in
/// ``TmuxControlModeGateway``; keeping the logic here makes it synchronously
/// testable with a fake transport.
public struct TmuxControlModeSessionCore: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Bytes to write to the gateway's stdin (a tmux command + newline).
        case write([UInt8])
        /// The initial snapshot to feed into the surface (before live output).
        case snapshot([UInt8])
        /// Live pane bytes to feed into the surface.
        case output([UInt8])
        case resizePolicy(TerminalSessionResizePolicy)
        /// The session ended.
        case ended(reason: String?)
        /// The control transport or protocol became untrustworthy. The
        /// caller may retry the attachment without claiming the pane ended.
        case failed(reason: String)
    }

    /// Each command we write is answered by exactly one `%begin`…`%end` block,
    /// in order, so we track what each pending response is for.
    private enum PendingCommand: Equatable {
        case flowControl   // refresh-client -f pause-after=...
        case ignore        // send-keys and other acknowledgements
        case resize        // refresh-client -C; gates latest-wins resize sends
        case resolvePane   // list-panes: parse the active pane id
        case pause         // refresh-client -A "...:pause"
        case foreground // display-message #{alternate_on}|#{pane_current_command}
        case snapshot      // capture-pane: collect replacement rows
        case state         // display-message: collect terminal state
        case resume        // refresh-client -A "...:continue"
        case foregroundSubscription // refresh-client -B live policy stream
    }

    /// Input that arrived before the control client completed its initial
    /// replacement snapshot. Sending it earlier would put user bytes in the
    /// same stream as the capture transaction, so the local surface could
    /// apply the bytes before the authoritative screen. Keep the original
    /// input order, including the distinction between literal bytes and a
    /// tmux key-table token.
    private enum PendingInput: Equatable {
        case bytes([UInt8])
        case namedKey(String)

        var budget: Int {
            switch self {
            case let .bytes(bytes): return bytes.count
            case let .namedKey(name): return name.utf8.count + 1
            }
        }
    }

    private var parser = TmuxControlModeParser()
    private var pending: [PendingCommand] = []
    /// Every tmux control-mode attach command emits one response block before
    /// any command sent by the client. Keep that protocol handshake separate
    /// from our FIFO. Treating it as the first `refresh-client` reply shifts
    /// every later response and makes the initial pane look disconnected.
    private var attachBlockPending = true
    private var targetPane: String?
    private let targetWindow: String?
    private var started = false
    private var resizeInFlight = false
    private var pendingResize: TerminalSize?
    private var lastClientGrid: TerminalSize.Grid?
    private var snapshotDelivered = false
    private var seedInFlight = false
    private var seedCaptureFinished = false
    private var seedAlternateScreen = false
    private var seedResizePolicy: TerminalSessionResizePolicy = .preserveScreen
    private var seedLines: [String] = []
    private var seedStateLine: String?
    private var seedFailureReason: String?
    private var pendingLiveOutput: [UInt8] = []
    private var ended = false
    private var foregroundSubscriptionInstalled = false
    private var foregroundSubscriptionPending = false
    private var foregroundSubscriptionDisabled = false
    private var pendingInput: [PendingInput] = []
    private var pendingInputHead = 0
    private var pendingInputBytes = 0

    /// `true` after tmux has emitted the attach command's initial response
    /// block. Gate the first client command on this boundary so a pty-backed
    /// `-CC` client has completed its terminal setup before command bytes are
    /// written. This also keeps the attach block out of the command FIFO.
    public private(set) var attachHandshakeComplete = false

    private static let maximumPendingLiveOutputBytes = 8 * 1024 * 1024
    private static let maximumPendingCommands = 8192
    private static let maximumPendingInputBytes = 8 * 1024 * 1024

    /// Creates a core with an optional pane selected by the caller. A pane
    /// target is important for Harbor: resolving the active pane after attach
    /// would silently display a different pane when another client changes
    /// focus during the handshake.
    public init(
        targetPaneID: String? = nil,
        targetWindowID: String? = nil,
        stripDCSFraming: Bool = false
    ) {
        self.parser = TmuxControlModeParser(stripDCSFraming: stripDCSFraming)
        self.targetPane = targetPaneID
        self.targetWindow = targetWindowID
    }

    /// Resolve the active pane, then capture it. The gateway has already been
    /// spawned for the chosen target; here we negotiate size and snapshot.
    public mutating func start(initialSize: TerminalSize) -> [Effect] {
        guard !started, !ended else { return [] }
        started = true
        var effects: [Effect] = []
        // Enable tmux's own flow-control boundary before requesting a pane
        // snapshot. If an older server rejects the flag, the explicit pause
        // around the initial seed still provides a lossless boundary.
        effects.append(writeCommand(
            TmuxControlModeEncoder.enableFlowControl(),
            as: .flowControl
        ))
        // A resize can arrive between surface creation and the control-mode
        // handshake. Use the newest value for the first client claim instead
        // of sending the stale size that was passed to `start`.
        let firstSize = pendingResize ?? initialSize
        pendingResize = nil
        resizeInFlight = true
        lastClientGrid = firstSize.grid
        effects.append(writeCommand(
            TmuxControlModeEncoder.refreshClientSize(firstSize, windowID: targetWindow),
            as: .resize
        ))
        if let targetPane {
            effects.append(contentsOf: beginSnapshotSequence(paneID: targetPane, alreadyPaused: false))
        } else {
            effects.append(writeCommand(TmuxControlModeEncoder.listActivePanes(), as: .resolvePane))
        }
        return effects
    }

    /// Feed raw gateway stdout.
    public mutating func consume(_ bytes: [UInt8]) -> [Effect] {
        guard !ended else { return [] }
        var effects: [Effect] = []
        for event in parser.consume(bytes) {
            handle(event, into: &effects)
            if ended { break }
        }
        return effects
    }

    /// Finish the parser at transport EOF. A final unterminated `%exit` can
    /// still be consumed, while an incomplete command block fails closed.
    public mutating func finishStream() -> [Effect] {
        guard !ended else { return [] }
        var effects: [Effect] = []
        for event in parser.finish() {
            handle(event, into: &effects)
            if ended { break }
        }
        return effects
    }

    public mutating func sendInput(_ bytes: [UInt8]) -> [Effect] {
        guard !ended, !bytes.isEmpty else { return [] }
        return routeInput(.bytes(bytes))
    }

    /// Forward a physical named key. The encoder rejects values that cannot be
    /// represented as one tmux key token, so malformed input never becomes a
    /// second command in the control stream.
    public mutating func sendNamedKey(_ name: String) -> [Effect] {
        guard !ended, !name.isEmpty else { return [] }
        // Validate before queueing. An invalid key must never remain in the
        // FIFO and fail a later, otherwise valid input sequence.
        guard TmuxControlModeEncoder.sendNamedKey(paneID: targetPane ?? "%0", keyName: name) != nil else {
            return []
        }
        return routeInput(.namedKey(name))
    }

    public mutating func resize(_ size: TerminalSize) -> [Effect] {
        guard !ended else { return [] }
        // AppKit may report several intermediate cell grids during one drag.
        // Keep only the latest intent and send it after the current tmux
        // command block resolves. This preserves protocol order without
        // allowing stale refresh-client commands to queue behind the user.
        pendingResize = size
        return issuePendingResizeIfPossible()
    }

    /// The gateway process exited.
    public mutating func gatewayExited(reason: String?) -> [Effect] {
        guard !ended else { return [] }
        ended = true
        return [.ended(reason: reason)]
    }

    /// The gateway lost its transport or detected a non-recoverable process
    /// failure. This is deliberately separate from `gatewayExited`, because a
    /// reason string alone cannot tell the UI whether the foreign terminal
    /// ended or the attachment failed.
    public mutating func gatewayFailed(reason: String) -> [Effect] {
        guard !ended else { return [] }
        ended = true
        return [.failed(reason: reason)]
    }

    // MARK: - Event handling

    private mutating func handle(_ event: TmuxControlModeEvent, into effects: inout [Effect]) {
        switch event {
        case .begin:
            break
        case let .commandResult(_, output, isError):
            if attachBlockPending {
                attachBlockPending = false
                attachHandshakeComplete = true
                if isError {
                    ended = true
                    let detail = output.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    effects.append(.failed(reason: detail.isEmpty ? "tmux attach failed" : detail))
                }
                return
            }
            // tmux's response number identifies the command block, but the
            // control-mode contract does not require it to be monotonic. The
            // parser already matches each `%end`/`%error` fence to its own
            // `%begin` number, and this FIFO matches completed blocks to the
            // commands we issued. Do not invent an ordering guarantee from
            // the numeric value. Reconnects and tmux implementations may
            // legally reuse or reset it.
            guard !pending.isEmpty else {
                ended = true
                effects.append(.failed(reason: "tmux returned an unsolicited command response"))
                return
            }
            let kind = pending.removeFirst()
            switch kind {
            case .flowControl:
                // `pause-after` is an optimization and is absent on some old
                // tmux versions. The explicit capture transaction remains
                // correct without it.
                break
            case .resize:
                resizeInFlight = false
                guard !isError else {
                    endWithCommandError(output, fallback: "tmux client resize failed", into: &effects)
                    return
                }
                effects.append(contentsOf: issuePendingResizeIfPossible())
            case .resolvePane:
                handleResolvePane(output: output, isError: isError, into: &effects)
            case .pause:
                guard !isError else {
                    endWithCommandError(output, fallback: "tmux pane pause failed", into: &effects)
                    return
                }
                // Everything before the pause is included in capture-pane. Do
                // not replay it after the replacement snapshot.
                pendingLiveOutput.removeAll(keepingCapacity: false)
            case .foreground:
                if !isError, let raw = output.first {
                    let state = TmuxPaneForegroundState(rawValue: raw)
                    seedAlternateScreen = state.alternateOn
                    seedResizePolicy = state.resizePolicy
                    effects.append(.resizePolicy(seedResizePolicy))
                } else {
                    seedResizePolicy = .preserveScreen
                    effects.append(.resizePolicy(.preserveScreen))
                }
            case .snapshot:
                if isError {
                    seedFailureReason = commandError(output, fallback: "tmux snapshot failed")
                } else {
                    seedLines = output
                    seedCaptureFinished = true
                }
            case .state:
                if !isError { seedStateLine = output.first }
                guard seedFailureReason == nil, seedCaptureFinished else {
                    if seedFailureReason == nil {
                        seedFailureReason = "tmux snapshot produced no capture"
                    }
                    return
                }
                let snapshot = TmuxControlModeSnapshot.render(
                    lines: seedLines,
                    alternateScreen: seedAlternateScreen,
                    stateLine: seedStateLine
                )
                snapshotDelivered = true
                effects.append(.snapshot(snapshot))
            case .resume:
                seedInFlight = false
                if isError {
                    endWithCommandError(output, fallback: "tmux pane resume failed", into: &effects)
                } else if let seedFailureReason {
                    ended = true
                    effects.append(.failed(reason: seedFailureReason))
                } else if !pendingLiveOutput.isEmpty {
                    effects.append(.output(pendingLiveOutput))
                    pendingLiveOutput.removeAll(keepingCapacity: false)
                }
                guard !ended else { return }
                // User input is released only after the replacement frame and
                // its resume acknowledgement. This makes the snapshot a real
                // ordering barrier instead of a best-effort redraw.
                effects.append(contentsOf: flushPendingInput())
                if !foregroundSubscriptionInstalled,
                   !foregroundSubscriptionPending,
                   !foregroundSubscriptionDisabled,
                   let pane = targetPane {
                    foregroundSubscriptionPending = true
                    effects.append(writeCommand(
                        TmuxControlModeEncoder.subscribePaneForeground(paneID: pane),
                        as: .foregroundSubscription
                    ))
                }
            case .ignore:
                // A completed send-keys response frees one bounded command
                // slot. Drain queued input in FIFO order when that happens.
                effects.append(contentsOf: flushPendingInput())
            case .foregroundSubscription:
                // The live subscription's value arrives as an asynchronous
                // notification. Its command acknowledgement only confirms
                // that tmux accepted the subscription.
                foregroundSubscriptionPending = false
                if !isError {
                    foregroundSubscriptionInstalled = true
                } else {
                    // Older tmux versions may not implement subscriptions.
                    // Keep the conservative preserve-screen policy and do not
                    // retry an unsupported command on every snapshot.
                    foregroundSubscriptionDisabled = true
                }
                break
            }
        case let .output(paneID, bytes):
            guard paneID == targetPane else { return }
            if seedInFlight || !snapshotDelivered {
                guard pendingLiveOutput.count <= Self.maximumPendingLiveOutputBytes - bytes.count else {
                    ended = true
                    effects.append(.failed(reason: "tmux output exceeded its bounded seed buffer"))
                    return
                }
                pendingLiveOutput.append(contentsOf: bytes)
            } else {
                effects.append(.output(bytes))
            }
        case let .notification(name, arguments):
            guard name == "pause",
                  let paneID = arguments.first,
                  paneID == targetPane,
                  !seedInFlight else { return }
            effects.append(contentsOf: beginSnapshotSequence(paneID: paneID, alreadyPaused: true))
        case let .subscriptionChanged(name, value):
            guard let pane = targetPane,
                  name == TmuxControlModeEncoder.foregroundSubscriptionName(paneID: pane)
            else { return }
            let state = TmuxPaneForegroundState(rawValue: value)
            effects.append(.resizePolicy(state.resizePolicy))
        case .exit(let reason):
            ended = true
            effects.append(.ended(reason: reason))
        case .clientDetached:
            ended = true
            effects.append(.ended(reason: "detached"))
        case let .protocolError(reason):
            ended = true
            effects.append(.failed(reason: reason))
        default:
            break
        }
    }

    private mutating func handleResolvePane(output: [String], isError: Bool, into effects: inout [Effect]) {
        guard !isError else {
            ended = true
            effects.append(.failed(reason: commandError(output, fallback: "tmux pane discovery failed")))
            return
        }
        guard let pane = Self.activePane(from: output) else {
            ended = true
            effects.append(.ended(reason: "no active tmux pane"))
            return
        }
        targetPane = pane
        effects.append(contentsOf: beginSnapshotSequence(paneID: pane, alreadyPaused: false))
    }

    private mutating func beginSnapshotSequence(paneID: String, alreadyPaused: Bool) -> [Effect] {
        guard !ended, !seedInFlight else { return [] }
        seedInFlight = true
        seedCaptureFinished = false
        seedAlternateScreen = false
        seedResizePolicy = .preserveScreen
        seedLines.removeAll(keepingCapacity: false)
        seedStateLine = nil
        seedFailureReason = nil
        if alreadyPaused {
            pendingLiveOutput.removeAll(keepingCapacity: false)
        }
        var effects: [Effect] = []
        if !alreadyPaused {
            effects.append(writeCommand(
                TmuxControlModeEncoder.pausePaneOutput(paneID: paneID),
                as: .pause
            ))
        }
        effects.append(writeCommand(
            TmuxControlModeEncoder.queryPaneForeground(paneID: paneID),
            as: .foreground
        ))
        effects.append(writeCommand(
            TmuxControlModeEncoder.capturePane(paneID: paneID),
            as: .snapshot
        ))
        effects.append(writeCommand(
            TmuxControlModeEncoder.queryPaneState(paneID: paneID),
            as: .state
        ))
        effects.append(writeCommand(
            TmuxControlModeEncoder.continuePaneOutput(paneID: paneID),
            as: .resume
        ))
        return effects
    }

    private mutating func endWithCommandError(
        _ output: [String],
        fallback: String,
        into effects: inout [Effect]
    ) {
        ended = true
        effects.append(.failed(reason: commandError(output, fallback: fallback)))
    }

    private func commandError(_ output: [String], fallback: String) -> String {
        let detail = output.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }

    // MARK: - Helpers

    private var inputReady: Bool {
        started && attachHandshakeComplete && targetPane != nil
            && snapshotDelivered && !seedInFlight && !ended
    }

    private mutating func routeInput(_ input: PendingInput) -> [Effect] {
        var effects: [Effect] = []
        // A queue can remain populated when the command FIFO was temporarily
        // full. Drain it before appending a newer input item so ordering is
        // explicit even under sustained paste traffic.
        if inputReady {
            effects.append(contentsOf: flushPendingInput())
        }
        if !inputReady || !pendingInputIsEmpty {
            guard enqueuePendingInput(input) else {
                ended = true
                return [.failed(reason: "tmux input queue exceeded its bounded byte limit")]
            }
            if inputReady {
                effects.append(contentsOf: flushPendingInput())
            }
            return effects
        }
        if emitInput(input, into: &effects) {
            return effects
        }
        guard enqueuePendingInput(input) else {
            ended = true
            return [.failed(reason: "tmux input queue exceeded its bounded byte limit")]
        }
        effects.append(contentsOf: flushPendingInput())
        return effects
    }

    private var pendingInputIsEmpty: Bool {
        pendingInputHead >= pendingInput.count
    }

    private mutating func enqueuePendingInput(_ input: PendingInput) -> Bool {
        let budget = input.budget
        guard budget <= Self.maximumPendingInputBytes - pendingInputBytes,
              pendingInput.count - pendingInputHead < Self.maximumPendingCommands
        else { return false }
        pendingInput.append(input)
        pendingInputBytes += budget
        return true
    }

    /// Emit as many queued input records as the outstanding command budget
    /// allows. The head index avoids `removeFirst()`'s repeated array shifts
    /// during a large paste.
    private mutating func flushPendingInput() -> [Effect] {
        guard inputReady, let pane = targetPane else { return [] }
        var effects: [Effect] = []
        while pendingInputHead < pendingInput.count {
            let input = pendingInput[pendingInputHead]
            guard emitInput(input, paneID: pane, into: &effects) else { break }
            pendingInputBytes -= input.budget
            pendingInputHead += 1
        }
        if pendingInputHead == pendingInput.count {
            pendingInput.removeAll(keepingCapacity: true)
            pendingInputHead = 0
        } else if pendingInputHead > 0, pendingInputHead * 2 >= pendingInput.count {
            pendingInput.removeFirst(pendingInputHead)
            pendingInputHead = 0
        }
        return effects
    }

    private mutating func emitInput(_ input: PendingInput, into effects: inout [Effect]) -> Bool {
        guard let pane = targetPane else { return false }
        return emitInput(input, paneID: pane, into: &effects)
    }

    private mutating func emitInput(
        _ input: PendingInput,
        paneID: String,
        into effects: inout [Effect]
    ) -> Bool {
        let commands: [String]
        switch input {
        case let .bytes(bytes):
            commands = TmuxControlModeEncoder.sendKeysCommands(paneID: paneID, bytes: bytes)
        case let .namedKey(name):
            guard let command = TmuxControlModeEncoder.sendNamedKey(paneID: paneID, keyName: name) else {
                return true
            }
            commands = [command]
        }
        guard pending.count <= Self.maximumPendingCommands - commands.count else { return false }
        effects.append(contentsOf: commands.map { writeCommand($0, as: .ignore) })
        return true
    }

    private mutating func writeCommand(_ command: String, as kind: PendingCommand) -> Effect {
        pending.append(kind)
        var bytes = Array(command.utf8)
        bytes.append(0x0A) // \n
        return .write(bytes)
    }

    private mutating func issuePendingResizeIfPossible() -> [Effect] {
        guard !ended, started, attachHandshakeComplete, !resizeInFlight, let size = pendingResize else { return [] }
        pendingResize = nil
        // tmux has no pixel-cell argument. A scale-only report must not create
        // a redundant client-size command or a needless pane redraw.
        guard lastClientGrid != size.grid else { return [] }
        resizeInFlight = true
        lastClientGrid = size.grid
        return [writeCommand(
            TmuxControlModeEncoder.refreshClientSize(size, windowID: targetWindow),
            as: .resize
        )]
    }

    /// Pick the active pane id from `list-panes -F '#{pane_active}:#{pane_id}'`
    /// output. Lines look like `1:%3` (active) / `0:%4`.
    static func activePane(from output: [String]) -> String? {
        for line in output {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let active = trimmed[trimmed.startIndex..<colon]
            let pane = String(trimmed[trimmed.index(after: colon)...])
            if active == "1", !pane.isEmpty { return pane }
        }
        // Fall back to the first listed pane if none is flagged active.
        for line in output {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let pane = String(trimmed[trimmed.index(after: colon)...])
            if !pane.isEmpty { return pane }
        }
        return nil
    }
}
