import Foundation

/// A coalescing, back-pressured queue of pending terminal input.
///
/// The buffer batches consecutive text destined for the same workspace/terminal
/// into one chunk, bounds total pending bytes to ``maximumPendingByteCount``, and
/// reports via ``MobileTerminalInputEnqueueResult`` whether the caller should
/// start a drain loop. It is a pure value type so the send loop's ordering and
/// overflow behavior can be tested deterministically.
public struct MobileTerminalInputSendBuffer: Equatable, Sendable {
    /// The maximum number of UTF-8 bytes that may sit pending before new input is rejected.
    public static let maximumPendingByteCount = 64 * 1024

    /// One coalesced run of pending input bound to a single terminal.
    public struct Chunk: Equatable, Sendable {
        /// The workspace the input is destined for.
        public var workspaceID: MobileWorkspacePreview.ID
        /// The terminal the input is destined for.
        public var terminalID: MobileTerminalPreview.ID
        /// The accumulated text for this chunk.
        public var text: String

        /// Creates a pending-input chunk.
        /// - Parameters:
        ///   - workspaceID: The destination workspace.
        ///   - terminalID: The destination terminal.
        ///   - text: The accumulated text.
        public init(
            workspaceID: MobileWorkspacePreview.ID,
            terminalID: MobileTerminalPreview.ID,
            text: String
        ) {
            self.workspaceID = workspaceID
            self.terminalID = terminalID
            self.text = text
        }
    }

    /// The chunks awaiting delivery, in FIFO order.
    public private(set) var pendingChunks: [Chunk] = []
    /// The total UTF-8 byte count currently pending.
    public private(set) var pendingByteCount = 0
    /// Whether a drain loop is currently running against this buffer.
    public private(set) var isDraining = false

    /// Creates an empty send buffer.
    public init() {}

    /// Enqueues text for delivery, coalescing it onto the last chunk when it
    /// targets the same terminal.
    /// - Parameters:
    ///   - text: The text to enqueue. Empty text is a no-op that returns `.queued`.
    ///   - workspaceID: The destination workspace.
    ///   - terminalID: The destination terminal.
    /// - Returns: Whether the caller should start draining, the text was queued, or it was rejected for overflow.
    public mutating func enqueue(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalInputEnqueueResult {
        guard !text.isEmpty else { return .queued }
        let byteCount = text.utf8.count
        guard pendingByteCount + byteCount <= Self.maximumPendingByteCount else {
            return .rejected
        }
        if var last = pendingChunks.last,
           last.workspaceID == workspaceID,
           last.terminalID == terminalID {
            last.text += text
            pendingChunks[pendingChunks.count - 1] = last
        } else {
            pendingChunks.append(
                Chunk(
                    workspaceID: workspaceID,
                    terminalID: terminalID,
                    text: text
                )
            )
        }
        pendingByteCount += byteCount
        guard !isDraining else { return .queued }
        isDraining = true
        return .startDraining
    }

    /// Removes and returns the next pending chunk, or clears the draining flag
    /// and returns `nil` when the buffer is empty.
    /// - Returns: The next chunk to deliver, or `nil` when nothing is pending.
    public mutating func nextBatch() -> Chunk? {
        guard !pendingChunks.isEmpty else {
            isDraining = false
            return nil
        }
        let chunk = pendingChunks.removeFirst()
        pendingByteCount = max(0, pendingByteCount - chunk.text.utf8.count)
        return chunk
    }

    /// Drops all pending input and resets the draining flag.
    public mutating func clear() {
        pendingChunks.removeAll()
        pendingByteCount = 0
        isDraining = false
    }
}
