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
            self.connection = connection
            guard let connection else { return }
            for line in pendingLines { connection.send(line: line) }
            pendingLines.removeAll(keepingCapacity: true)
            pendingByteCount = 0
        }
    }

    /// Stops delivery and discards queued bytes during permanent pane teardown.
    func invalidate() {
        queue.async { [self] in
            connection = nil
            pendingLines.removeAll(keepingCapacity: false)
            pendingByteCount = 0
        }
    }

    /// Enqueues one manual input event.
    func send(_ input: TerminalManualInput) {
        // Keep base64/JSON work off Ghostty's synchronous I/O callback. The
        // callback only copies the already-owned Sendable value and enqueues it
        // on this serial transport lane.
        queue.async { [self, input] in
            let command: [String: Any]
            switch input {
            case .bytes(let bytes):
                guard !bytes.isEmpty else { return }
                // Request id zero is reserved for untracked input frames. The
                // mirror session uses positive ids for handshake/resize state,
                // so an input acknowledgement can never be mistaken for one
                // of its state-machine responses.
                command = commandBuilder.input(
                    surfaceID: surfaceID,
                    bytes: bytes,
                    requestID: 0
                )
            case .namedKey(let name):
                guard let key = Self.protocolKeyName(for: name) else { return }
                command = commandBuilder.namedKey(
                    surfaceID: surfaceID,
                    key: key,
                    requestID: 0
                )
            }
            guard let line = commandBuilder.line(command) else { return }
            if let connection {
                connection.send(line: line)
                return
            }
            guard pendingByteCount + line.count <= pendingByteLimit else {
                pendingLines.removeAll(keepingCapacity: true)
                pendingByteCount = 0
                return
            }
            pendingLines.append(line)
            pendingByteCount += line.count
        }
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
