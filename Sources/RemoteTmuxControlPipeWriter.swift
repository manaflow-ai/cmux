import Foundation

/// Bounded off-main writer for the SSH control client's stdin pipe.
///
/// `RemoteTmuxControlConnection` records command FIFO entries on the main actor
/// before this writer can emit bytes, so tmux `%begin`/`%end` replies cannot
/// outrun their local correlation slot. The write itself may block on a stalled
/// SSH pipe; keeping it on this serial queue prevents that from freezing UI.
@MainActor
final class RemoteTmuxControlPipeWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let onFailure: @MainActor @Sendable () -> Void
    private var closed = false
    private var pendingBytes = 0

    init(
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

    func enqueue(_ data: Data) -> Bool {
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

    func close() {
        guard !closed else { return }
        closed = true
        queue.async { [handle] in
            try? handle.close()
        }
    }
}
