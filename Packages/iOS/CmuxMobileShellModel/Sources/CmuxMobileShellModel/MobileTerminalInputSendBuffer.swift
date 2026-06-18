import Foundation

/// A coalescing, back-pressured queue of pending terminal input.
///
/// The buffer batches consecutive text destined for the same workspace/terminal
/// into one chunk, bounds total pending backlog to ``maximumPendingByteCount``,
/// and reports via ``MobileTerminalInputEnqueueResult`` whether the caller
/// should start a drain loop. One oversized input event may enter an empty
/// queue up to ``maximumSingleInputByteCount`` so large pastes are not mistaken
/// for backlog pressure.
public struct MobileTerminalInputSendBuffer: Equatable, Sendable {
    /// The maximum number of UTF-8 bytes that may sit pending before new input is rejected.
    ///
    /// A single input event larger than this cap, but no larger than
    /// ``maximumSingleInputByteCount``, is accepted only when there is no
    /// pending backlog and drains in batches bounded by this value.
    public static let maximumPendingByteCount = 64 * 1024

    /// The absolute UTF-8 byte limit for one input event accepted into an empty queue.
    public static let maximumSingleInputByteCount = maximumPendingByteCount * 16

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
        let acceptsSingleOversizedInput = pendingChunks.isEmpty
            && pendingByteCount == 0
            && byteCount <= Self.maximumSingleInputByteCount
        // A single oversized input (a large paste) transiently pushes
        // `pendingByteCount` above ``maximumPendingByteCount`` until the drain
        // loop's first ``nextBatch()`` splits it into bounded batches. While
        // exactly that one oversized chunk is pending, accept follow-on input
        // (bounded by the absolute single-input ceiling) instead of rejecting
        // it: a keystroke delivered right after a large paste — before the
        // scheduled drain task runs its first split — must not be turned into a
        // queue-overflow disconnect (issue #6082). Normal backlog pressure
        // (``pendingByteCount`` at or below ``maximumPendingByteCount``) is
        // unaffected, so a genuinely full queue still rejects.
        let drainingSingleOversizedChunk = pendingChunks.count == 1
            && pendingByteCount > Self.maximumPendingByteCount
            && pendingByteCount + byteCount <= Self.maximumSingleInputByteCount
        guard pendingByteCount + byteCount <= Self.maximumPendingByteCount
            || acceptsSingleOversizedInput
            || drainingSingleOversizedChunk else {
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

    /// Removes and returns the next bounded pending chunk, or clears the
    /// draining flag and returns `nil` when the buffer is empty.
    /// - Returns: The next chunk to deliver, or `nil` when nothing is pending.
    public mutating func nextBatch() -> Chunk? {
        guard !pendingChunks.isEmpty else {
            isDraining = false
            return nil
        }
        let chunk = pendingChunks.removeFirst()
        let chunkByteCount = chunk.text.utf8.count
        if chunkByteCount > Self.maximumPendingByteCount {
            let splitIndex = chunk.text.mobileTerminalInputBoundedSplitIndex(
                maximumUTF8ByteCount: Self.maximumPendingByteCount
            )
            let prefix = String(chunk.text[..<splitIndex])
            let remainder = String(chunk.text[splitIndex...])
            if !remainder.isEmpty {
                pendingChunks.insert(
                    Chunk(
                        workspaceID: chunk.workspaceID,
                        terminalID: chunk.terminalID,
                        text: remainder
                    ),
                    at: 0
                )
            }
            pendingByteCount = max(0, pendingByteCount - prefix.utf8.count)
            return Chunk(
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID,
                text: prefix
            )
        }
        pendingByteCount = max(0, pendingByteCount - chunkByteCount)
        return chunk
    }

    /// Drops all pending input and resets the draining flag.
    public mutating func clear() {
        pendingChunks.removeAll()
        pendingByteCount = 0
        isDraining = false
    }
}

private extension String {
    func mobileTerminalInputBoundedSplitIndex(maximumUTF8ByteCount: Int) -> String.Index {
        var index = startIndex
        var byteCount = 0
        while index < endIndex {
            let nextIndex = self.index(after: index)
            let nextByteCount = self[index..<nextIndex].utf8.count
            guard byteCount + nextByteCount <= maximumUTF8ByteCount else {
                break
            }
            byteCount += nextByteCount
            index = nextIndex
        }
        return index == startIndex ? self.index(after: startIndex) : index
    }
}
