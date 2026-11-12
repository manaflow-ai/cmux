import Darwin

/// Borrows a descriptor for writes without changing a shared socket's signal policy.
struct CLIWriteDescriptor {
    let fileDescriptor: Int32
    private let isSocket: Bool

    /// Creates a writer for an already-open descriptor.
    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        var status = stat()
        isSocket = fstat(fileDescriptor, &status) == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }

    /// Enables the descriptor-level pipe guard for non-socket descriptors.
    func setPipeNoSIGPIPE(_ enabled: Bool) {
        guard !isSocket else { return }
        // F_SETNOSIGPIPE on a socket changes its shared SO_NOSIGPIPE option,
        // which other writers and inherited child descriptors can observe.
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, enabled ? 1 : 0)
    }

    /// Writes bytes while suppressing SIGPIPE on socket descriptors.
    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        // F_SETNOSIGPIPE can fail after a socket disconnects. MSG_NOSIGNAL
        // protects even that first send without affecting any other writer.
        if isSocket {
            return Darwin.send(fileDescriptor, buffer, count, MSG_NOSIGNAL)
        }
        return Darwin.write(fileDescriptor, buffer, count)
    }
}
