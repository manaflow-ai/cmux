import Foundation

/// Resolves when a unix socket path accepts a connection.
///
/// The hub binary owns the moment it starts listening, so readiness is observed
/// rather than assumed: a vnode watch on the socket's directory wakes the probe
/// when the file appears, and a real `connect(2)` confirms a listener is behind
/// it. No polling loop; the only timer is the bounded overall timeout.
enum CloudWireGuardHubSocketReadiness {
    enum ReadinessError: Error, LocalizedError, Equatable {
        case timedOut(String)
        case directoryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let path):
                return "no listener appeared at \(path) in time"
            case .directoryUnavailable(let path):
                return "cannot watch \(path) for the hub socket"
            }
        }
    }

    /// A `connect(2)` probe answers readiness directly, but a listening Unix
    /// socket has no kqueue edge for the bind→listen transition: the socket file
    /// exists after `bind`, and no later vnode event fires when `listen` starts
    /// accepting. So a directory vnode watch is only an accelerator for the file
    /// appearing; a bounded probe cadence is what actually detects "accepts now".
    static let probeInterval: Duration = .milliseconds(100)

    static func wait(
        socketPath: String,
        timeout: Duration,
        probeInterval: Duration = Self.probeInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }
    ) async throws {
        if accepts(socketPath) { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        let watchFd = open(directory, O_EVTONLY)
        guard watchFd >= 0 else { throw ReadinessError.directoryUnavailable(directory) }
        let ready = CloudLinkFirstValue<Bool>()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFd,
            eventMask: [.write, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            if accepts(socketPath) { ready.resolve(true) }
        }
        source.setCancelHandler { close(watchFd) }
        source.resume()
        defer { source.cancel() }
        if accepts(socketPath) { return }
        let outcome: Bool = await withTaskGroup(of: Bool.self) { group in
            // The watch resolves this the instant the file appears and accepts.
            group.addTask { await ready.result ?? false }
            // The probe cadence catches the bind→listen edge the watch cannot see.
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: timeout)
                while ContinuousClock.now < deadline {
                    if accepts(socketPath) { return true }
                    do {
                        try await sleep(probeInterval)
                    } catch {
                        return false
                    }
                }
                return accepts(socketPath)
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard outcome else { throw ReadinessError.timedOut(socketPath) }
    }

    /// Whether a listener currently accepts connections at `socketPath`.
    static func accepts(_ socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        return result == 0
    }
}
