import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Quit Everything decides from acpmux's locks once the socket is gone or
/// refuses. A daemon the quit census saw and that is now gone, with no agent
/// host left, ended; a socket file nobody answers on with daemon.lock free
/// is no daemon. Neither is a failure, on the first attempt or on a Retry.
struct AcpmuxQuitProofTests {
    /// A short acpmux home (a socket path must fit in `sun_path`).
    private struct Home {
        let url: URL
        let environment: AcpmuxEnvironment
        var socket: String { environment.socketPath }

        init() throws {
            url = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("aqp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("hosts"), withIntermediateDirectories: true)
            environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: url,
                                            socketPath: url.appendingPathComponent("acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        /// What a crashed daemon leaves: a bound socket file with no listener.
        func leaveStaleSocket() throws {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.lastError() }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socket.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                path.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw Self.lastError() }
        }

        /// Holds daemon.lock the way a live (or shutting-down) daemon does.
        /// Returns the descriptor; closing it releases the lock.
        func holdDaemonLock() throws -> Int32 {
            let fd = open(url.appendingPathComponent("daemon.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Self.lastError() }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let error = Self.lastError()
                close(fd)
                throw error
            }
            return fd
        }

        private static func lastError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @Test func aStaleSocketWithAFreeLockIsNoDaemonOnEveryAttempt() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.leaveStaleSocket()

        // The quit dialog's census (and the updater's once-a-second census) sees the socket file.
        _ = await AcpmuxQuit.census(home.environment)

        #expect(await AcpmuxQuit.endAgents(home.environment) == .noDaemon)
        _ = await AcpmuxQuit.census(home.environment)
        #expect(await AcpmuxQuit.endAgents(home.environment, waitForShutdown: true, within: .seconds(1)) == .noDaemon)
        #expect(await AcpmuxQuit.endAgents(home.environment, waitForShutdown: true, within: .seconds(1)) == .noDaemon)
    }

    @Test func aDaemonThatExitedAfterTheCensusEnded() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.leaveStaleSocket()
        _ = await AcpmuxQuit.census(home.environment)

        // It shut down cleanly before Quit Everything: socket removed, daemon.lock free, no host.
        try FileManager.default.removeItem(atPath: home.socket)

        #expect(await AcpmuxQuit.endAgents(home.environment) == .ended)
        // The census sighting is spent: a later attempt with nothing seen is no daemon.
        #expect(await AcpmuxQuit.endAgents(home.environment, waitForShutdown: true, within: .seconds(1)) == .noDaemon)
    }

    @Test func aCensusedDaemonStillHoldingItsLockIsAShutdownInProgress() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.leaveStaleSocket()
        _ = await AcpmuxQuit.census(home.environment)
        let lock = try home.holdDaemonLock()
        defer { close(lock) }
        try FileManager.default.removeItem(atPath: home.socket)

        #expect(await AcpmuxQuit.endAgents(home.environment) == .shutdownInProgress(pid: nil))
    }

    @Test func anUncensusedMissingSocketRemainsNoDaemon() async throws {
        let home = try Home()
        defer { home.remove() }

        #expect(await AcpmuxQuit.endAgents(home.environment) == .noDaemon)
    }
}
