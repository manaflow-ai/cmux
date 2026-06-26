import Foundation

/// Bounded off-main writer for the SSH control client's stdin pipe.
///
/// ``RemoteTmuxControlConnection`` records command FIFO entries on the main actor
/// before this writer can emit bytes, so tmux `%begin`/`%end` replies cannot
/// outrun their local correlation slot. The write itself may block on a stalled
/// SSH pipe; keeping it on this serial queue prevents that from freezing UI.
@MainActor
public final class RemoteTmuxControlPipeWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let onFailure: @MainActor @Sendable () -> Void
    private var closed = false
    private var pendingBytes = 0

    /// Creates a writer bound to `handle` (the stdin pipe's write end).
    ///
    /// - Parameters:
    ///   - handle: the SSH control client's stdin write handle.
    ///   - label: serial-queue label identifying this writer (the connection
    ///     passes a per-spawn unique label).
    ///   - maxPendingBytes: cap on bytes queued but not yet written; ``enqueue(_:)``
    ///     rejects a write that would exceed it.
    ///   - onFailure: invoked on the main actor when a write throws (a broken pipe
    ///     or closed SSH child). The connection reconnects in response; the closure
    ///     stays app-side and is injected here.
    public init(
        handle: FileHandle,
        label: String,
        maxPendingBytes: Int,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = maxPendingBytes
        self.onFailure = onFailure
    }

    /// Queues `data` for the serial writer. Returns `false` (rejecting the write)
    /// when the writer is closed or the pending-byte budget would be exceeded, so
    /// the connection can reconnect instead of accepting unbounded backpressure.
    public func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard !closed,
              data.count <= maxPendingBytes - pendingBytes else {
            return false
        }
        pendingBytes += data.count

        queue.async { [weak self, handle, data] in
            var didFail = false
            do {
                try handle.write(contentsOf: data)
            } catch {
                didFail = true
            }
            Task { @MainActor [weak self] in
                self?.finishWrite(byteCount: data.count, didFail: didFail)
            }
        }
        return true
    }

    private func finishWrite(byteCount: Int, didFail: Bool) {
        pendingBytes = max(0, pendingBytes - byteCount)
        if didFail, !closed {
            onFailure()
        }
    }

    /// Closes the pipe handle off-main and stops accepting further writes.
    public func close() {
        guard !closed else { return }
        closed = true
        queue.async { [handle] in
            try? handle.close()
        }
    }
}
