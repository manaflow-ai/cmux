import CmuxNextAgentActivity
import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// Holds one socket scope across launches. A crash releases the lock.
nonisolated final class ComputerUseHelperScope: Sendable {
    let socketPath: String
    private let descriptor: Int32

    private init(socketPath: String, descriptor: Int32) {
        self.socketPath = socketPath
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    @concurrent static func acquire(socketPath: String, stateDirectory: URL) async -> ComputerUseHelperScope? {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        guard ComputerUseHelperDaemon.makePrivateDirectory(directory.deletingLastPathComponent().path),
              ComputerUseHelperDaemon.makePrivateDirectory(directory.path),
              ComputerUseHelperDaemon.makePrivateDirectory(stateDirectory.path) else { return nil }
        let fd = open(directory.appending(path: "owner.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return ComputerUseHelperScope(socketPath: socketPath, descriptor: fd)
    }

    /// Old credentials are unknown. Stop every signed helper on this exact socket
    /// before removing its socket or starting one with fresh credentials.
    @concurrent func prepareForLaunch(stateDirectory: URL,
                                      candidates: @Sendable (String) -> [pid_t] = ComputerUseHelperScope.candidates,
                                      stop: @Sendable (pid_t) -> Bool = { ComputerUseHelperScope.stopHelper($0) }) async -> Bool {
        guard ComputerUseHelperDaemon.makePrivateDirectory(stateDirectory.path) else { return false }
        for pid in candidates(socketPath) {
            guard stop(pid) else { return false }
        }
        return unlink(socketPath) == 0 || errno == ENOENT
    }

    private static func candidates(_ socketPath: String) -> [pid_t] {
        ProcessUsage.processes(pathPrefix: "/").filter { pid in
            guard let path = ProcessUsage.path(of: pid), (path as NSString).lastPathComponent == "cmux-cua" else { return false }
            return serves(socketPath, arguments: ProcessUsage.arguments(of: pid))
        }
    }

    /// A candidate that already exited (between the scan and here) counts as stopped.
    static func stopHelper(_ pid: pid_t, isAlive: (pid_t) -> Bool = ComputerUseHelperScope.isAlive,
                           isSigned: (pid_t) -> Bool = ComputerUseHelperScope.isSignedHelper,
                           stopAndWait: (pid_t) -> Bool = ComputerUseHelperScope.stopAndWait) -> Bool {
        guard isAlive(pid) else { return true }
        guard isSigned(pid) else { return !isAlive(pid) }
        return stopAndWait(pid)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func serves(_ socketPath: String, arguments: [String]) -> Bool {
        guard arguments.count > 1, arguments[1] == "serve",
              let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == socketPath
    }

    static func isSignedHelper(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(CuaHelperIdentity.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// A bounded kernel exit event, off the main actor. A slow stop prevents a new launch.
    static func stopAndWait(_ pid: pid_t) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return errno == ESRCH }
        guard kill(pid, SIGTERM) == 0 else { return errno == ESRCH }
        var event = kevent()
        var deadline = timespec(tv_sec: 5, tv_nsec: 0)
        // concurrency-allow: called only by @concurrent prepareForLaunch, off the main actor; bounded to five seconds.
        return kevent(queue, nil, 0, &event, 1, &deadline) == 1 && event.fflags & UInt32(NOTE_EXIT) != 0
    }
}
