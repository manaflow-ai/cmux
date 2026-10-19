import Darwin

/// A `fcntl(2)` write lock on a spool lock file, held until deallocation.
///
/// Cross-process exclusion is the point of this type: the kernel releases the
/// lock when the holder exits, which is how producers detect a dead forwarder.
/// The descriptor is immutable and only closed in `deinit`, so the type is
/// safe to share.
public final class AgentHookSpoolLock: Sendable {
    private let fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        // Closing the descriptor releases its fcntl lock.
        Darwin.close(fileDescriptor)
    }
}
