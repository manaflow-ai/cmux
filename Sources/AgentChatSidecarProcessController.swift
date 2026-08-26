import Darwin
import Foundation

/// Launches an app-owned agent-chat command in a child-led process group.
struct AgentChatSidecarProcessController {
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
            NSLog("[AgentChat] SHELL is not set; cannot launch startCommand")
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
            // A successful spawn is suspended, so a rejected identity means
            // it has already exited after the short retry window.  Reap only
            // when the kernel confirms a zombie; never issue a cleanup signal
            // from an unvalidated PID.
            if AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: processIdentifier) {
                Self.reap(processIdentifier)
            }
            return nil
        }
        guard Darwin.getpgid(processIdentifier) == processIdentifier else {
            // The identity is valid but the child-led group invariant failed;
            // terminate that exact process generation, never the bare PID.
            let didTerminate = AgentChatSidecarProcessTerminator().terminateValidatedProcess(identity)
            if didTerminate || AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: processIdentifier) {
                Self.reap(processIdentifier)
            }
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
            handle.terminate()
            return nil
        }
        return handle
    }

    private static func reap(_ processIdentifier: pid_t) {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { return }
            if result == -1 && errno == EINTR { continue }
            return
        }
    }

    /// `posix_spawn` publishes the child before the process-table sysctl is
    /// guaranteed to observe it on every macOS build.  Retry briefly while the
    /// child is still suspended; a persistent absence is treated as an
    /// identity failure and therefore fails closed.
    private static func captureSpawnedIdentity(_ processIdentifier: pid_t) -> AgentPIDProcessIdentity? {
        for attempt in 0..<8 {
            if let identity = AgentPIDProcessIdentity(pid: processIdentifier) {
                return identity
            }
            if AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: processIdentifier) {
                return nil
            }
            if attempt < 7 { usleep(1_000) }
        }
        return nil
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
