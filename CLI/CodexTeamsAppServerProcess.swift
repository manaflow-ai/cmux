import Darwin
import Foundation

/// Owns the app-server process launched for one Codex Teams session.
///
/// Codex is commonly installed through a Node launcher. Killing that launcher
/// alone does not reliably kill its native child, so the app-server is started
/// in a private process group with two parent-lifetime watchdogs. One channel
/// belongs to the launching CLI and one belongs to the watcher; either process
/// disappearing sends SIGTERM to the complete group, allowing the Node launcher
/// to forward the signal and the native app-server to shut down cleanly.
final class CodexTeamsAppServerProcess {
    private let processIdentifierValue: pid_t
    private let lifetimePipe: Pipe
    private let watcherLifetimePipe: Pipe
    private var watcherLifetimeTransferred = false
    private var cachedTerminationStatus: Int32? = nil
    private var didCloseLifetime = false

    init(
        supervisorExecutablePath: String,
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        logURL: URL?
    ) throws {
        let lifetimePipe = Pipe()
        let readFD = lifetimePipe.fileHandleForReading.fileDescriptor
        let writeFD = lifetimePipe.fileHandleForWriting.fileDescriptor
        let watcherLifetimePipe = Pipe()
        let watcherReadFD = watcherLifetimePipe.fileHandleForReading.fileDescriptor
        let watcherWriteFD = watcherLifetimePipe.fileHandleForWriting.fileDescriptor
        var fileActions: posix_spawn_file_actions_t?
        let fileActionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsStatus == 0 else {
            throw CodexTeamsPOSIXSupport.error(operation: "initialize Codex Teams process actions", code: fileActionsStatus)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try CodexTeamsPOSIXSupport.require(
            posix_spawn_file_actions_adddup2(&fileActions, readFD, STDIN_FILENO),
            operation: "connect Codex Teams lifetime pipe"
        )
        if readFD != STDIN_FILENO {
            try CodexTeamsPOSIXSupport.require(
                posix_spawn_file_actions_addclose(&fileActions, readFD),
                operation: "close Codex Teams lifetime read end"
            )
        }
        if writeFD > STDERR_FILENO {
            try CodexTeamsPOSIXSupport.require(
                posix_spawn_file_actions_addclose(&fileActions, writeFD),
                operation: "close Codex Teams lifetime write end"
            )
        }
        try CodexTeamsPOSIXSupport.require(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                watcherReadFD,
                CodexTeamsPOSIXSupport.watcherLifetimeFileDescriptor
            ),
            operation: "connect Codex Teams watcher lifetime pipe"
        )
        if watcherReadFD != CodexTeamsPOSIXSupport.watcherLifetimeFileDescriptor {
            try CodexTeamsPOSIXSupport.require(
                posix_spawn_file_actions_addclose(&fileActions, watcherReadFD),
                operation: "close Codex Teams watcher lifetime read end"
            )
        }
        if watcherWriteFD > STDERR_FILENO,
           watcherWriteFD != CodexTeamsPOSIXSupport.watcherLifetimeFileDescriptor {
            try CodexTeamsPOSIXSupport.require(
                posix_spawn_file_actions_addclose(&fileActions, watcherWriteFD),
                operation: "close Codex Teams watcher lifetime write end"
            )
        }

        if let logURL {
            try CodexTeamsPOSIXSupport.require(
                logURL.path.withCString {
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        STDOUT_FILENO,
                        $0,
                        O_WRONLY | O_CREAT | O_TRUNC | O_APPEND,
                        S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
                    )
                },
                operation: "redirect Codex Teams stdout"
            )
            try CodexTeamsPOSIXSupport.require(
                logURL.path.withCString {
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        STDERR_FILENO,
                        $0,
                        O_WRONLY | O_CREAT | O_APPEND,
                        S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
                    )
                },
                operation: "redirect Codex Teams stderr"
            )
        } else {
            try CodexTeamsPOSIXSupport.require(
                "/dev/null".withCString {
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        STDOUT_FILENO,
                        $0,
                        O_WRONLY,
                        0
                    )
                },
                operation: "redirect Codex Teams stdout"
            )
            try CodexTeamsPOSIXSupport.require(
                "/dev/null".withCString {
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        STDERR_FILENO,
                        $0,
                        O_WRONLY,
                        0
                    )
                },
                operation: "redirect Codex Teams stderr"
            )
        }

        var attributes: posix_spawnattr_t?
        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else {
            throw CodexTeamsPOSIXSupport.error(operation: "initialize Codex Teams process attributes", code: attributesStatus)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "configure Codex Teams process group"
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "configure Codex Teams process group leader"
        )

        let targetExecutable = executablePath.hasPrefix("/") ? executablePath : "/usr/bin/env"
        let targetArguments = executablePath.hasPrefix("/")
            ? arguments
            : [executablePath] + arguments
        let supervisorExecutable = supervisorExecutablePath.hasPrefix("/")
            ? supervisorExecutablePath
            : "/usr/bin/env"
        let supervisorArguments = supervisorExecutablePath.hasPrefix("/")
            ? ["__codex-teams-app-server-supervisor", targetExecutable] + targetArguments
            : [
                supervisorExecutablePath,
                "__codex-teams-app-server-supervisor",
                targetExecutable
            ] + targetArguments
        let argv = [supervisorExecutable] + supervisorArguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment ?? [:] {
            mergedEnvironment[key] = value
        }
        let environmentStrings = mergedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        var processIdentifier: pid_t = 0
        let spawnStatus = try CodexTeamsPOSIXSupport.withCStringArray(argv) { argvPointer in
            try CodexTeamsPOSIXSupport.withCStringArray(environmentStrings) { environmentPointer in
                supervisorExecutable.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard spawnStatus == 0 else {
            throw CodexTeamsPOSIXSupport.error(operation: "launch Codex Teams app-server", code: spawnStatus)
        }
        guard processIdentifier > 1 else {
            throw CodexTeamsPOSIXSupport.error(operation: "launch Codex Teams app-server", code: EINVAL)
        }
        guard getpgid(processIdentifier) == processIdentifier else {
            _ = Darwin.kill(processIdentifier, SIGKILL)
            _ = waitpid(processIdentifier, nil, 0)
            throw CodexTeamsPOSIXSupport.error(
                operation: "isolate Codex Teams app-server process group",
                code: EPERM
            )
        }

        try? lifetimePipe.fileHandleForReading.close()
        try? watcherLifetimePipe.fileHandleForReading.close()
        guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            _ = waitpid(processIdentifier, nil, 0)
            throw CodexTeamsPOSIXSupport.error(
                operation: "resume Codex Teams app-server",
                code: errno
            )
        }
        self.processIdentifierValue = processIdentifier
        self.lifetimePipe = lifetimePipe
        self.watcherLifetimePipe = watcherLifetimePipe
    }

    var processIdentifier: pid_t {
        processIdentifierValue
    }

    /// Closes the launcher-owned lifetime signal.
    func closeParentLifetimeForTesting() {
        closeParentLifetime()
    }

    /// Closes the watcher-owned lifetime signal.
    func closeWatcherLifetimeForTesting() {
        closeWatcherLifetime()
    }

    /// Transfers the watcher lifetime endpoint to the watcher process.
    func takeWatcherLifetimeWriteHandle() -> FileHandle {
        watcherLifetimeTransferred = true
        return watcherLifetimePipe.fileHandleForWriting
    }

    var isRunning: Bool {
        guard cachedTerminationStatus == nil else { return false }
        var status: Int32 = 0
        let result = waitpid(processIdentifierValue, &status, WNOHANG)
        if result == processIdentifierValue {
            cachedTerminationStatus = Self.decodedTerminationStatus(status)
            return false
        }
        if result == -1, errno == ECHILD {
            cachedTerminationStatus = -1
            return false
        }
        return true
    }

    func terminate() {
        closeParentLifetime()
        closeWatcherLifetime()
    }

    @discardableResult
    func waitUntilExit(timeout: TimeInterval = 2) -> Bool {
        guard cachedTerminationStatus == nil else { return true }
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var registration = kevent(
            ident: UInt(processIdentifierValue),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &registration, 1, nil, 0, nil) == 0 else {
            if errno != ESRCH { return false }
            return reapBlocking()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var event = kevent()
            let result = kevent(queue, nil, 0, &event, 1, &timeoutSpec)
            if result > 0 {
                return reapBlocking()
            }
            if result == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
    }

    func forceTerminate() {
        closeParentLifetime()
        closeWatcherLifetime()
        guard cachedTerminationStatus == nil else { return }
        _ = Darwin.kill(-processIdentifierValue, SIGKILL)
        _ = waitUntilExit(timeout: 2)
    }

    private func reapBlocking() -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifierValue, &status, 0)
            if result == processIdentifierValue {
                cachedTerminationStatus = Self.decodedTerminationStatus(status)
                return true
            }
            if result == -1, errno == EINTR {
                continue
            }
            cachedTerminationStatus = -1
            return false
        }
    }

    deinit {
        forceTerminate()
    }

    private func closeParentLifetime() {
        guard !didCloseLifetime else { return }
        didCloseLifetime = true
        try? lifetimePipe.fileHandleForWriting.close()
    }

    private func closeWatcherLifetime() {
        guard !watcherLifetimeTransferred else { return }
        try? watcherLifetimePipe.fileHandleForWriting.close()
    }

    private static func decodedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return 128 + signal
    }

}
