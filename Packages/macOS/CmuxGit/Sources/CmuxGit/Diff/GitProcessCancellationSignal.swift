import Darwin

/// A level-triggered cancellation wake-up shared by one logical Git query
/// and each subprocess that query starts.
///
/// Safety: descriptors are immutable, POSIX writes are thread-safe, and every
/// concurrent cancellation call retains this object for the call's duration.
final class GitProcessCancellationSignal: @unchecked Sendable {
    let readDescriptor: Int32
    private let writeDescriptor: Int32

    init() {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0,
              gitProcessConfigureCancellationDescriptor(descriptors[0]),
              gitProcessConfigureCancellationDescriptor(descriptors[1]) else {
            for descriptor in descriptors where descriptor >= 0 {
                close(descriptor)
            }
            readDescriptor = -1
            writeDescriptor = -1
            return
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    deinit {
        if readDescriptor >= 0 { close(readDescriptor) }
        if writeDescriptor >= 0 { close(writeDescriptor) }
    }

    func cancel() {
        guard writeDescriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) {
            write(writeDescriptor, $0, MemoryLayout<UInt8>.size)
        }
    }
}

private func gitProcessConfigureCancellationDescriptor(_ descriptor: Int32) -> Bool {
    let statusFlags = fcntl(descriptor, F_GETFL)
    guard statusFlags >= 0,
          fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
        return false
    }
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    return descriptorFlags >= 0
        && fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
}
