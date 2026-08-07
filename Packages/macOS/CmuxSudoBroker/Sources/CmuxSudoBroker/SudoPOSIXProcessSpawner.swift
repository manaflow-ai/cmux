import Darwin
import Foundation

struct SudoPOSIXProcessSpawner: SudoProcessSpawning {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess {
        let outputDescriptor = Darwin.open(
            command.outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard outputDescriptor >= 0 else {
            throw SudoPOSIXSpawnError.outputOpenFailed(errno)
        }
        defer { Darwin.close(outputDescriptor) }
        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput { _ = unlink(command.outputURL.path) }
        }

        var fileActions: posix_spawn_file_actions_t?
        try Self.requireSuccess(
            posix_spawn_file_actions_init(&fileActions),
            error: { .fileActionsFailed($0) }
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var actionStatus = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                path,
                O_RDONLY,
                0
            )
        }
        if actionStatus == 0 {
            actionStatus = command.currentDirectoryURL.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
        }
        if actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                outputDescriptor,
                STDOUT_FILENO
            )
        }
        if actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                outputDescriptor,
                STDERR_FILENO
            )
        }
        if actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_addclose(&fileActions, outputDescriptor)
        }
        try Self.requireSuccess(actionStatus, error: { .fileActionsFailed($0) })

        var attributes: posix_spawnattr_t?
        try Self.requireSuccess(
            posix_spawnattr_init(&attributes),
            error: { .attributesFailed($0) }
        )
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.requireSuccess(
            posix_spawnattr_setpgroup(&attributes, 0),
            error: { .attributesFailed($0) }
        )
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        try Self.requireSuccess(
            posix_spawnattr_setflags(&attributes, flags),
            error: { .attributesFailed($0) }
        )

        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        guard (command.arguments + environment).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw SudoPOSIXSpawnError.invalidCString
        }

        var processIdentifier: pid_t = 0
        let spawnStatus = try Self.withCStringArray(command.arguments) { arguments in
            try Self.withCStringArray(environment) { environment in
                command.executableURL.path.withCString { executable in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else {
            throw SudoPOSIXSpawnError.spawnFailed(
                spawnStatus == 0 ? ECHILD : spawnStatus
            )
        }
        shouldRemoveOutput = false

        guard let identity = inspector.identity(for: processIdentifier) else {
            _ = kill(-processIdentifier, SIGKILL)
            _ = kill(processIdentifier, SIGKILL)
            Self.reap(processIdentifier)
            throw SudoPOSIXSpawnError.identityUnavailable
        }
        return SudoSpawnedProcess(
            identity: identity,
            processGroupIdentifier: processIdentifier
        )
    }

    private static func requireSuccess(
        _ status: Int32,
        error: (Int32) -> SudoPOSIXSpawnError
    ) throws {
        guard status == 0 else { throw error(status) }
    }

    private static func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw SudoPOSIXSpawnError.allocationFailed
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SudoPOSIXSpawnError.allocationFailed
            }
            return try operation(baseAddress)
        }
    }

    private static func reap(_ processIdentifier: pid_t) {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
    }
}

private enum SudoPOSIXSpawnError: Error {
    case outputOpenFailed(Int32)
    case fileActionsFailed(Int32)
    case attributesFailed(Int32)
    case invalidCString
    case allocationFailed
    case spawnFailed(Int32)
    case identityUnavailable
}
