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

    /// tmux prefix handling. Keys arrive already encoded, so the prefix is the
    /// control byte (Ctrl-b = 0x02 by default). We intercept `<prefix> d` to
    /// detach; any other prefixed key is passed through literally (so Ctrl-b
    /// still works in the pane for unmapped chords).
    private static let prefixByte: UInt8 = 0x02 // Ctrl-b
    private static let detachKey: UInt8 = 0x64  // 'd'
    private var awaitingPrefixChord = false

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
        var effects: [Effect] = []
        var passthrough: [UInt8] = []
        func flush() {
            guard !passthrough.isEmpty else { return }
            effects.append(.write(commandBytes(TmuxControlModeEncoder.sendKeys(paneID: pane, bytes: passthrough))))
            passthrough.removeAll(keepingCapacity: true)
        }
        for byte in bytes {
            if awaitingPrefixChord {
                awaitingPrefixChord = false
                if byte == Self.detachKey {
                    flush()
                    effects.append(.write(commandBytes(TmuxControlModeEncoder.detachClient())))
                } else {
                    // Unmapped chord: pass the prefix and key through literally.
                    passthrough.append(Self.prefixByte)
                    passthrough.append(byte)
                }
            } else if byte == Self.prefixByte {
                awaitingPrefixChord = true
            } else {
                passthrough.append(byte)
            }
        }
        flush()
        return effects
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
        // Trim trailing blank rows (capture-pane pads to the screen height) and
        // emit no trailing newline, so the snapshot anchors at the top of the
        // surface with the cursor right after the last real line — matching how
        // the pane looks in tmux instead of sinking to the bottom.
        var lines = output
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let bytes = Array(lines.joined(separator: "\r\n").utf8)
        effects.append(.snapshot(bytes))
        // Any pane output buffered before the capture-pane result is already
        // reflected in the snapshot, so drop it rather than replaying it (which
        // would duplicate the last line, e.g. a second prompt).
        pendingLiveOutput.removeAll(keepingCapacity: false)
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
