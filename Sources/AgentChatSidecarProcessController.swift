import Darwin
import Foundation
import os

private nonisolated let agentChatSidecarProcessLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentChatSidecarProcess"
)

/// Launches an app-owned agent-chat command in a child-led process group.
nonisolated struct AgentChatSidecarProcessController {
    typealias SpawnedIdentityProvider = @Sendable (pid_t) -> AgentPIDProcessIdentity?
    typealias ShellPathProvider = @Sendable () -> String?

    private let spawnedIdentityProvider: SpawnedIdentityProvider
    private let shellPathProvider: ShellPathProvider

    /// Creates a controller with injectable process identity and shell lookups.
    init(
        spawnedIdentityProvider: @escaping SpawnedIdentityProvider = { pid in
            AgentPIDProcessIdentity(pid: pid)
        },
        shellPathProvider: @escaping ShellPathProvider = {
            ProcessInfo.processInfo.environment["SHELL"]
        }
    ) {
        self.spawnedIdentityProvider = spawnedIdentityProvider
        self.shellPathProvider = shellPathProvider
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    /// Launches a suspended, identity-validated sidecar and resumes its group.
    func launch(
        command: String,
        launchId: String,
        currentDirectoryURL: URL,
        environmentOverrides: [String: String]
    ) async -> AgentChatSidecarProcessHandle? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let shellPath = shellPathProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        guard let identity = spawnedIdentityProvider(processIdentifier) else {
            // The child is still suspended and unreaped.  That direct-child
            // relationship is a stronger launch identity than a stored PID:
            // the kernel cannot reuse this number until this parent reaps it.
            // Revalidate that relationship and its child-led group before
            // signaling; never kill a bare PID discovered from state.
            _ = await AgentChatSidecarProcessHandle.terminateDirectChild(processIdentifier)
            return nil
        }
        guard Darwin.getpgid(processIdentifier) == processIdentifier else {
            // The identity is valid but the child-led group invariant failed;
            // terminate that exact direct-child generation, never a bare PID
            // from a persisted state file.
            _ = await AgentChatSidecarProcessHandle.terminateDirectChild(
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
            // The handle owns the suspended child now. Let its identity-safe
            // termination path perform group cleanup, then use the shared
            // direct-child helper only when the synchronous path cannot prove
            // that the root was reaped before returning.
            if !handle.terminate() {
                _ = await AgentChatSidecarProcessHandle.terminateDirectChild(
                    processIdentifier,
                    expectedIdentity: identity
                )
            }
            return nil
        }
        return handle
    }

    /// Calls `body` with a null-terminated, temporarily allocated C string array.
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
