import CmuxTerminal
import CmuxCloudImagePaste
import Foundation

/// Sends Ghostty manual-surface input to a remote cmux-tui PTY.
///
/// The router is safe to call from Ghostty's I/O thread. It queues encoded
/// command lines until an attachment is ready, preserving input order across a
/// reconnect without touching MainActor state.
// @unchecked Sendable is safe because all mutable pending-input state is
// isolated to `queue`; callers cross the boundary only with immutable input
// values and the connection's thread-safe enqueue operation.
public final class CloudTuiManualIOInputRouter: @unchecked Sendable {
    private var surfaceID: UInt64
    private let queue: DispatchQueue
    private let commandBuilder: CloudTuiManualIOCommand
    private var connection: CloudTuiManualIOConnection?
    private var pendingLines: [Data] = []
    /// Consecutive byte input is safe to coalesce because the PTY observes one
    /// ordered byte stream. Keeping it as bytes until the router queue turn
    /// completes avoids one JSON/base64 frame and one socket enqueue per key
    /// when a user types quickly.
    private var pendingByteInput = Data()
    private var byteFlushScheduled = false
    private let pendingByteLimit = 256 * 1024
    private var pendingByteCount = 0

    public init(
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
    public func updateSurfaceID(_ surfaceID: UInt64) {
        queue.async { [self, surfaceID] in
            guard self.surfaceID != surfaceID else { return }
            let previousSurfaceID = self.surfaceID
            self.surfaceID = surfaceID
            if previousSurfaceID == 0, connection == nil {
                // The first authenticated attachment resolves an unknown target.
                // Retain early input, in order, for that exact initial binding.
                pendingLines = pendingLines.compactMap { line in
                    guard var command = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
                    command["surface"] = surfaceID
                    return commandBuilder.line(command)
                }
                pendingByteCount = pendingLines.reduce(0) { $0 + $1.count }
                return
            }
            // Pending lines already contain the old numeric target. Dropping
            // them is safer than delivering input to a reused surface slot;
            // subsequent keystrokes are encoded for the new ID.
            pendingLines.removeAll(keepingCapacity: true)
            pendingByteCount = 0
        }
    }

    /// Rebinds pending input to a newly connected transport.
    public func setConnection(_ connection: CloudTuiManualIOConnection?) {
        queue.async { [self, connection] in
            flushPendingByteInput()
            self.connection = connection
            guard let connection else { return }
            for line in pendingLines { connection.send(line: line) }
            pendingLines.removeAll(keepingCapacity: true)
            pendingByteCount = 0
        }
    }

    /// Stops delivery and discards queued bytes during permanent pane teardown.
    public func invalidate() {
        queue.async { [self] in
            connection = nil
            pendingLines.removeAll(keepingCapacity: false)
            pendingByteInput.removeAll(keepingCapacity: false)
            byteFlushScheduled = false
            pendingByteCount = 0
        }
    }

    /// Orders a control request with the manual input that preceded the paste.
    public func sendControl(
        _ command: [String: Any], on connection: CloudTuiManualIOConnection, requestID: UInt64
    ) throws -> UInt64 {
        let command = command.merging(["id": requestID]) { _, value in value }
        guard let line = commandBuilder.line(command) else {
            throw CloudImagePasteError.unavailable
        }
        // Image commit shares the input lane. Queue it behind prior manual input,
        // and retain this exact connection rather than replaying it after reconnect.
        queue.async { [self] in
            // Control requests are ordering barriers. Flush bytes typed before
            // the request before putting the control line on the transport.
            flushPendingByteInput()
            connection.send(line: line)
        }
        return requestID
    }

    /// Enqueues one manual input event.
    public func send(_ input: TerminalManualInput) {
        // Keep base64/JSON work off Ghostty's synchronous I/O callback. The
        // callback only copies the already-owned Sendable value and enqueues it
        // on this serial transport lane.
        queue.async { [self, input] in
            let command: [String: Any]
            switch input {
            case .bytes(let bytes):
                guard !bytes.isEmpty else { return }
                pendingByteInput.append(bytes)
                guard !byteFlushScheduled else { return }
                byteFlushScheduled = true
                // A later byte already queued on this serial lane is folded
                // into the same frame. There is no timer or sleep here, so a
                // single keystroke still takes only one dispatch turn.
                queue.async { [self] in flushPendingByteInput() }
                return
            case .namedKey(let name):
                flushPendingByteInput()
                guard let key = Self.protocolKeyName(for: name) else { return }
                command = commandBuilder.namedKey(
                    surfaceID: surfaceID,
                    key: key,
                    requestID: 0
                )
            }
            enqueue(line: commandBuilder.line(command))
        }
    }

    private func flushPendingByteInput() {
        guard !pendingByteInput.isEmpty else {
            byteFlushScheduled = false
            return
        }
        let bytes = pendingByteInput
        pendingByteInput.removeAll(keepingCapacity: true)
        byteFlushScheduled = false
        // Request id zero is reserved for untracked input frames. The mirror
        // session uses positive ids for handshake/resize state, so an input
        // acknowledgement can never be mistaken for one of its responses.
        enqueue(line: commandBuilder.line(commandBuilder.input(
            surfaceID: surfaceID, bytes: bytes, requestID: 0
        )))
    }

    private func enqueue(line: Data?) {
        guard let line else { return }
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

    public static func protocolKeyName(for name: String) -> String? {
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
