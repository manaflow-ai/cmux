import Darwin
import Foundation
import os

private nonisolated let agentChatSidecarProcessLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentChatSidecarProcess"
)

/// Launches an app-owned agent-chat command in a child-led process group.
nonisolated struct AgentChatSidecarProcessController {
    func launch(
        command: String,
        launchId: String,
        currentDirectoryURL: URL,
        environmentOverrides: [String: String]
    ) -> AgentChatSidecarProcessHandle? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let shellPath = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shellPath.isEmpty else {
            agentChatSidecarProcessLogger.error("SHELL is not set; cannot launch startCommand")
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let configured = "/dev/null".withCString { nullPath in
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, nullPath, O_RDONLY, 0) == 0
                && posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, nullPath, O_WRONLY, 0) == 0
                && posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, nullPath, O_WRONLY, 0) == 0
        }
        let directoryConfigured: Bool
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            directoryConfigured = currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir(&actions, $0) == 0
            }
        } else {
            directoryConfigured = currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0) == 0
            }
        }
#else
        directoryConfigured = currentDirectoryURL.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0) == 0
        }
#endif
        guard configured, directoryConfigured else {
            return nil
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let arguments = [shellPath, "-lc", trimmedCommand]
        let mergedEnvironment = environment.merging(environmentOverrides) { _, override in override }
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnStatus = Self.withCStringArray(arguments) { argv in
            Self.withCStringArray(mergedEnvironment) { envp in
                shellPath.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &actions,
                        &attributes,
                        argv,
                        envp
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 0 else {
            return nil
        }
        guard let identity = Self.captureSpawnedIdentity(processIdentifier) else {
            // The child is still suspended and unreaped.  That direct-child
            // relationship is a stronger launch identity than a stored PID:
            // the kernel cannot reuse this number until this parent reaps it.
            // Revalidate that relationship and its child-led group before
            // signaling; never kill a bare PID discovered from state.
            _ = Self.terminateSuspendedSpawnedChild(processIdentifier)
            return nil
        }
        guard Darwin.getpgid(processIdentifier) == processIdentifier else {
            // The identity is valid but the child-led group invariant failed;
            // terminate that exact direct-child generation, never a bare PID
            // from a persisted state file.
            _ = Self.terminateSuspendedSpawnedChild(
                processIdentifier,
                expectedIdentity: identity
            )
            return nil
        }

        let handle = AgentChatSidecarProcessHandle(
            launchId: launchId,
            rootIdentity: identity,
            processGroupID: processIdentifier
        )
        // The child is suspended until the process group and exit watcher are
        // installed. Revalidate the birth token/group before resuming it.
        guard AgentPIDProcessIdentity(pid: processIdentifier) == identity,
              Darwin.getpgid(processIdentifier) == processIdentifier,
              Darwin.kill(-processIdentifier, SIGCONT) == 0 else {
            _ = handle.terminate()
            _ = Self.terminateSuspendedSpawnedChild(
                processIdentifier,
                expectedIdentity: identity
            )
            return nil
        }
        return handle
    }

    /// Reaps a direct child without blocking the caller. The dispatch source
    /// remains retained by its event handler until the kernel reports exit.
    private static func reapWhenExited(_ processIdentifier: pid_t) {
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier || (result == -1 && errno == ECHILD) {
            return
        }
        guard result == 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            var status: Int32 = 0
            _ = waitpid(processIdentifier, &status, WNOHANG)
            source.cancel()
        }
        source.resume()
    }

    /// `posix_spawn` publishes the child before the process-table sysctl is
    /// guaranteed to observe it on every macOS build. A missing token is a
    /// launch failure; the caller uses direct-child ownership to terminate the
    /// suspended child instead of guessing from a persisted PID.
    private static func captureSpawnedIdentity(_ processIdentifier: pid_t) -> AgentPIDProcessIdentity? {
        AgentPIDProcessIdentity(pid: processIdentifier)
    }

    /// Terminates a child that has not yet been resumed. `waitpid` proves that
    /// the caller still owns the direct child, so the PID cannot have been
    /// recycled; the process-group check then protects the negative signal.
    /// This is the only setup-failure path allowed to fall back to the positive
    /// PID when the group attribute itself was rejected by the kernel.
    @discardableResult
    private static func terminateSuspendedSpawnedChild(
        _ processIdentifier: pid_t,
        expectedIdentity: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        var status: Int32 = 0
        while true {
            let waitResult = waitpid(processIdentifier, &status, WNOHANG)
            if waitResult == processIdentifier || (waitResult == -1 && errno == ECHILD) {
                return true
            }
            if waitResult == -1 && errno == EINTR { continue }
            guard waitResult == 0 else { return false }
            if let expectedIdentity {
                guard AgentPIDProcessIdentity(pid: processIdentifier) == expectedIdentity else {
                    return false
                }
            }
            let groupID = Darwin.getpgid(processIdentifier)
            let target = groupID == processIdentifier ? -processIdentifier : processIdentifier
            errno = 0
            let signalResult = Darwin.kill(target, SIGKILL)
            if signalResult != 0, errno != ESRCH { return false }
            reapWhenExited(processIdentifier)
            return true
        }
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
