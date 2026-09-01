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
        /// The session ended.
        case ended(reason: String?)
    }

    /// Each command we write is answered by exactly one `%begin`…`%end` block,
    /// in order, so we track what each pending response is for.
    private enum PendingCommand: Equatable {
        case ignore        // refresh-client, send-keys: result discarded
        case resolvePane   // list-panes: parse the active pane id
        case snapshot      // capture-pane: deliver as the initial snapshot
    }

    private var parser = TmuxControlModeParser()
    private var pending: [PendingCommand] = []

    private var targetPane: String?
    private var snapshotDelivered = false
    private var pendingLiveOutput: [UInt8] = []
    private var ended = false

    public init() {}

    /// Resolve the active pane, then capture it. The gateway has already been
    /// spawned for the chosen target; here we negotiate size and snapshot.
    public mutating func start(initialSize: TerminalSize) -> [Effect] {
        var effects: [Effect] = []
        effects.append(writeCommand(TmuxControlModeEncoder.refreshClientSize(initialSize), as: .ignore))
        effects.append(writeCommand(TmuxControlModeEncoder.listActivePanes(), as: .resolvePane))
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

    public mutating func sendInput(_ bytes: [UInt8]) -> [Effect] {
        guard !ended, let pane = targetPane, !bytes.isEmpty else { return [] }
        return [writeCommand(TmuxControlModeEncoder.sendKeys(paneID: pane, bytes: bytes), as: .ignore)]
    }

    public mutating func resize(_ size: TerminalSize) -> [Effect] {
        guard !ended else { return [] }
        return [writeCommand(TmuxControlModeEncoder.refreshClientSize(size), as: .ignore)]
    }

    /// The gateway process exited.
    public mutating func gatewayExited(reason: String?) -> [Effect] {
        guard !ended else { return [] }
        ended = true
        return [.ended(reason: reason)]
    }

    // MARK: - Event handling

    private mutating func handle(_ event: TmuxControlModeEvent, into effects: inout [Effect]) {
        switch event {
        case .begin:
            break
        case let .commandResult(_, output, isError):
            let kind = pending.isEmpty ? nil : pending.removeFirst()
            switch kind {
            case .resolvePane:
                handleResolvePane(output: output, isError: isError, into: &effects)
            case .snapshot:
                deliverSnapshot(output: output, into: &effects)
            case .ignore, .none:
                break
            }
        case let .output(paneID, bytes):
            guard paneID == targetPane else { return }
            if snapshotDelivered {
                effects.append(.output(bytes))
            } else {
                pendingLiveOutput.append(contentsOf: bytes)
            }
        case .exit(let reason):
            ended = true
            effects.append(.ended(reason: reason))
        case .clientDetached:
            ended = true
            effects.append(.ended(reason: "detached"))
        default:
            break
        }
    }

    private mutating func handleResolvePane(output: [String], isError: Bool, into effects: inout [Effect]) {
        guard !isError, let pane = Self.activePane(from: output) else {
            ended = true
            effects.append(.ended(reason: "no active tmux pane"))
            return
        }
        targetPane = pane
        effects.append(writeCommand(TmuxControlModeEncoder.capturePane(paneID: pane), as: .snapshot))
    }

    private mutating func deliverSnapshot(output: [String], into effects: inout [Effect]) {
        guard !snapshotDelivered else { return }
        snapshotDelivered = true
        var bytes = Array(output.joined(separator: "\r\n").utf8)
        if !output.isEmpty { bytes.append(contentsOf: [0x0D, 0x0A]) } // trailing CRLF
        effects.append(.snapshot(bytes))
        if !pendingLiveOutput.isEmpty {
            effects.append(.output(pendingLiveOutput))
            pendingLiveOutput.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Helpers

    private mutating func writeCommand(_ command: String, as kind: PendingCommand) -> Effect {
        pending.append(kind)
        var bytes = Array(command.utf8)
        bytes.append(0x0A) // \n
        return .write(bytes)
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
