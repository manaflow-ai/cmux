import Foundation

/// Pure orchestration for a local tmux control-mode session, with no process
/// or threading. It turns gateway input + caller intents into a list of
/// ``Effect`` values (bytes to write to the gateway, snapshot/output to feed
/// the surface, end-of-session). The Process- and queue-bound wrapper lives in
/// ``TmuxControlModeGateway``; keeping the logic here makes it synchronously
/// testable with a fake transport.
///
/// Command responses are matched by **content/phase**, not by a positional
/// queue: tmux emits spontaneous `%begin`/`%end` blocks on entry (e.g. an
/// initial empty block), so a positional FIFO desyncs. Instead we send
/// `list-panes` and treat the first command block whose output parses as a pane
/// list as the resolver; the first block after we request `capture-pane` is the
/// snapshot; everything else (the entry block, `refresh-client`/`send-keys`
/// acknowledgements) is ignored.
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

    private enum Phase: Equatable {
        case resolvingPane   // waiting for a command block that parses as a pane list
        case capturing       // capture-pane requested; next command block is the snapshot
        case live            // snapshot delivered; command blocks are acknowledgements
    }

    private var parser = TmuxControlModeParser()
    private var phase: Phase = .resolvingPane

    private var targetPane: String?
    private var pendingLiveOutput: [UInt8] = []
    private var ended = false

    public init() {}

    /// Negotiate size, then ask tmux for its panes so we can resolve the one to
    /// render. The gateway has already been spawned for the chosen target.
    public mutating func start(initialSize: TerminalSize) -> [Effect] {
        var effects: [Effect] = []
        effects.append(.write(commandBytes(TmuxControlModeEncoder.refreshClientSize(initialSize))))
        effects.append(.write(commandBytes(TmuxControlModeEncoder.listActivePanes())))
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
        return [.write(commandBytes(TmuxControlModeEncoder.sendKeys(paneID: pane, bytes: bytes)))]
    }

    public mutating func resize(_ size: TerminalSize) -> [Effect] {
        guard !ended else { return [] }
        return [.write(commandBytes(TmuxControlModeEncoder.refreshClientSize(size)))]
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
        case let .commandResult(_, output, isError):
            switch phase {
            case .resolvingPane:
                // Ignore the entry block, refresh-client ack, and any other
                // block that is not the pane list. Only resolve on a real list.
                guard !isError, let pane = Self.activePane(from: output) else { return }
                targetPane = pane
                phase = .capturing
                effects.append(.write(commandBytes(TmuxControlModeEncoder.capturePane(paneID: pane))))
            case .capturing:
                deliverSnapshot(output: output, into: &effects)
                phase = .live
            case .live:
                break
            }
        case let .output(paneID, bytes):
            guard paneID == targetPane else { return }
            if phase == .live {
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

    private mutating func deliverSnapshot(output: [String], into effects: inout [Effect]) {
        var bytes = Array(output.joined(separator: "\r\n").utf8)
        if !output.isEmpty { bytes.append(contentsOf: [0x0D, 0x0A]) } // trailing CRLF
        effects.append(.snapshot(bytes))
        if !pendingLiveOutput.isEmpty {
            effects.append(.output(pendingLiveOutput))
            pendingLiveOutput.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Helpers

    private func commandBytes(_ command: String) -> [UInt8] {
        var bytes = Array(command.utf8)
        bytes.append(0x0A) // \n
        return bytes
    }

    /// Pick the active pane id from `list-panes -F '#{pane_active}:#{pane_id}'`
    /// output. Lines look like `1:%3` (active) / `0:%4`. Returns nil if no line
    /// parses as a pane entry (so non-pane command blocks are skipped).
    static func activePane(from output: [String]) -> String? {
        var firstPane: String?
        for line in output {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let active = trimmed[trimmed.startIndex..<colon]
            let pane = String(trimmed[trimmed.index(after: colon)...])
            guard pane.hasPrefix("%"), pane.count > 1 else { continue }
            if firstPane == nil { firstPane = pane }
            if active == "1" { return pane }
        }
        return firstPane
    }
}
