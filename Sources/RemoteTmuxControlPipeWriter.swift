import CmuxTmuxControlMode
import Foundation

/// Compatibility façade for the SSH control client's stdin pipe.
///
/// Command correlation remains owned by `RemoteTmuxControlConnection`, while
/// byte delivery is delegated to the shared nonblocking writer. Keeping this
/// façade preserves the main-actor test seam and prevents the legacy remote
/// mirror from silently using a weaker transport implementation than Harbor.
@MainActor
final class RemoteTmuxControlPipeWriter {
    private let writer: ControlModeProcessInputWriter
    private var closed = false

    init(
        handle: FileHandle,
        label: String,
        maxPendingBytes: Int,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.writer = ControlModeProcessInputWriter(
            label: label,
            maxPendingBytes: maxPendingBytes,
            onFailure: { _ in
                // The remote connection is main-actor isolated. The shared
                // writer reports from its worker, so hop explicitly instead
                // of relying on an accidental queue affinity.
                Task { @MainActor in
                    onFailure()
                }
            }
        )
        self.writer.attach(to: handle)
    }

    func enqueue(_ data: Data) -> Bool {
        guard !closed else { return false }
        return writer.enqueue(data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        writer.close()
    }
}
