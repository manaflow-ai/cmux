import CmuxTerminal
import Foundation

/// Sends Ghostty manual-surface input to a remote cmux-tui PTY.
///
/// The router is safe to call from Ghostty's I/O thread. It queues encoded
/// command lines until an attachment is ready, preserving input order across a
/// reconnect without touching MainActor state.
// @unchecked Sendable is safe because all mutable pending-input state is
// isolated to `queue`; callers cross the boundary only with immutable input
// values and the connection's thread-safe enqueue operation.
final class CloudTuiManualIOInputRouter: @unchecked Sendable {
    private var surfaceID: UInt64
    private let queue: DispatchQueue
    private let commandBuilder: CloudTuiManualIOCommand
    private var connection: CloudTuiManualIOConnection?
    private var pendingLines: [Data] = []
    private let pendingByteLimit = 256 * 1024
    private var pendingByteCount = 0
    private let inputChunkByteLimit = 16 * 1024
    private var inputBytes = Data()
    private var inputFlushScheduled = false
    private let admission = CloudTuiManualIOAdmission()

    init(
        surfaceID: UInt64,
        queue: DispatchQueue = DispatchQueue(label: "com.cmux.cloud-manual-io-input", qos: .userInitiated),
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand()
    ) {
        self.surfaceID = surfaceID
        self.queue = queue
        self.commandBuilder = commandBuilder
    }

    /// Updates the numeric surface target after a cmux-tui daemon restart.
    /// Public terminal resource IDs survive a restart, while the compatibility
    /// tree's numeric surface IDs may be allocated again.
    func updateSurfaceID(_ surfaceID: UInt64) {
        queue.async { [self, surfaceID] in
            guard self.surfaceID != surfaceID else { return }
            self.surfaceID = surfaceID
            inputBytes.removeAll(keepingCapacity: true)
            // Pending lines already contain the old numeric target. Dropping
            // them is safer than delivering input to a reused surface slot;
            // subsequent keystrokes are encoded for the new ID.
            pendingLines.removeAll(keepingCapacity: true)
            pendingByteCount = 0
        }
    }

    /// Rebinds pending input to a newly connected transport.
    func setConnection(_ connection: CloudTuiManualIOConnection?) {
        queue.async { [self, connection] in
            if connection != nil, !admission.reopen() { return }
            flushInputBytes()
            self.connection = connection
            guard connection != nil else { return }
            var handedOff = 0
            for line in pendingLines {
                guard handOff(line) else { break }
                handedOff += 1
                pendingByteCount -= line.count
            }
            // Only false is known not to have been retained. Replaying a true
            // handoff after a transport failure could duplicate remote input.
            pendingLines.removeFirst(handedOff)
        }
    }

    /// Stops delivery and discards queued bytes during permanent pane teardown.
    func invalidate() {
        admission.invalidate()
        queue.async { [self] in
            connection = nil
            inputBytes.removeAll(keepingCapacity: false)
            pendingLines.removeAll(keepingCapacity: false)
            pendingByteCount = 0
        }
    }

    /// Enqueues one manual input event.
    /// Returns whether callback capacity was reserved, not whether input arrived.
    @discardableResult
    func send(_ input: TerminalManualInput) -> Bool {
        let cost: Int
        switch input {
        case .bytes(let bytes): cost = bytes.count
        case .namedKey(let name): cost = name.utf8.count
        }
        switch admission.reserve(cost) {
        case .closed: return false
        case .rejected:
            queue.async { [self] in connection?.close() }
            return false
        case .reserved: break
        }
        // Keep base64/JSON work off Ghostty's synchronous I/O callback. The
        // callback only copies the already-owned Sendable value and enqueues it
        // on this serial transport lane.
        queue.async { [self, input] in
            defer { admission.release(cost) }
            switch input {
            case .bytes(let bytes):
                guard !bytes.isEmpty else { return }
                var offset = bytes.startIndex
                while offset < bytes.endIndex {
                    let end = bytes.index(offset, offsetBy: min(
                        inputChunkByteLimit - inputBytes.count,
                        bytes.distance(from: offset, to: bytes.endIndex)
                    ))
                    inputBytes.append(bytes[offset..<end])
                    offset = end
                    if inputBytes.count == inputChunkByteLimit { flushInputBytes() }
                }
                guard !inputFlushScheduled else { return }
                inputFlushScheduled = true
                // One queue turn collects already-enqueued keystrokes. No
                // timer delays an isolated key, and the 16 KiB chunk bound
                // prevents a paste from becoming an oversized JSON command.
                queue.async { [self] in
                    inputFlushScheduled = false
                    flushInputBytes()
                }
            case .namedKey(let name):
                guard let key = Self.protocolKeyName(for: name) else { return }
                flushInputBytes()
                sendCommand(commandBuilder.namedKey(
                    surfaceID: surfaceID,
                    key: key,
                    requestID: 0
                ))
            }
        }
        return true
    }

    private func flushInputBytes() {
        guard !inputBytes.isEmpty else { return }
        // Zero remains outside the mirror's handshake/geometry request IDs.
        sendCommand(commandBuilder.input(surfaceID: surfaceID, bytes: inputBytes, requestID: 0))
        inputBytes.removeAll(keepingCapacity: true)
    }

    private func sendCommand(_ command: [String: Any]) {
        guard let line = commandBuilder.line(command) else { return }
        if handOff(line) { return }
        guard pendingByteCount + line.count <= pendingByteLimit else {
            // Keep earlier known-unsent input intact when this buffer fills.
            // Stop admitting callbacks until a ready connection can drain it.
            admission.saturate()
            return
        }
        pendingLines.append(line)
        pendingByteCount += line.count
    }

    /// Direct input and pending replay share the same known-unsent decision.
    private func handOff(_ line: Data) -> Bool {
        guard let connection else { return false }
        if connection.sendInput(line: line) { return true }
        self.connection = nil
        return false
    }

    private static func protocolKeyName(for name: String) -> String? {
        let pieces = name.split(separator: "-").map(String.init)
        guard let rawBase = pieces.last else { return nil }
        let modifiers = pieces.dropLast().compactMap { piece -> String? in
            switch piece.lowercased() {
            case "c", "ctrl", "control": return "ctrl"
            case "m", "alt", "option": return "alt"
            case "s", "shift": return "shift"
            default: return nil
            }
        }
        guard modifiers.count == pieces.count - 1 else { return nil }
        let base: String
        switch rawBase.lowercased() {
        case "up": base = "up"
        case "down": base = "down"
        case "left": base = "left"
        case "right": base = "right"
        case "home": base = "home"
        case "end": base = "end"
        case "dc", "delete": base = "delete"
        case "ic", "insert": base = "insert"
        case "ppage", "pageup": base = "pageup"
        case "npage", "pagedown": base = "pagedown"
        case "esc", "escape": base = "escape"
        case "return", "enter": base = "enter"
        case "tab": base = "tab"
        case "btab", "backtab": base = "backtab"
        case "backspace", "bspace", "bs": base = "backspace"
        case "space": base = "space"
        case let value where value.first == "f" && Int(value.dropFirst()) != nil: base = value
        case let value where value.count == 1: base = value
        default: return nil
        }
        return (modifiers + [base]).joined(separator: "+")
    }
}
