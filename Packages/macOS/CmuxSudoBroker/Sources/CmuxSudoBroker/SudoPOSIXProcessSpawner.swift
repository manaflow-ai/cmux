import Darwin
import Foundation

struct SudoPOSIXProcessSpawner: SudoProcessSpawning {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess {
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        defer {
            for descriptor in Set(inputPipe + outputPipe) where descriptor >= 0 {
                Darwin.close(descriptor)
            }
        }

        if command.standardInput != nil {
            guard Darwin.pipe(&inputPipe) == 0 else {
                throw SudoPOSIXSpawnError.pipeFailed(errno)
            }
            try Self.configureParentDescriptor(inputPipe[1])
        }
        guard Darwin.pipe(&outputPipe) == 0 else {
            throw SudoPOSIXSpawnError.pipeFailed(errno)
        }
        try Self.configureParentDescriptor(outputPipe[0])

        let outputDescriptor = Darwin.open(
            command.outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard outputDescriptor >= 0 else {
            throw SudoPOSIXSpawnError.outputOpenFailed(errno)
        }
        var shouldCloseOutput = true
        defer {
            if shouldCloseOutput { Darwin.close(outputDescriptor) }
        }
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
            if inputPipe[0] >= 0 {
                posix_spawn_file_actions_adddup2(
                    &fileActions,
                    inputPipe[0],
                    STDIN_FILENO
                )
            } else {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            }
        }
        if actionStatus == 0 {
            actionStatus = command.currentDirectoryURL.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
        }
        if actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                outputPipe[1],
                STDOUT_FILENO
            )
        }
        if actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_adddup2(
                &fileActions,
                outputPipe[1],
                STDERR_FILENO
            )
        }
        let childDescriptors = Set(inputPipe + outputPipe + [outputDescriptor])
        for descriptor in childDescriptors where actionStatus == 0 && descriptor > STDERR_FILENO {
            actionStatus = posix_spawn_file_actions_addclose(&fileActions, descriptor)
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

        let environment = SudoProcessEnvironment().entries
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
        if inputPipe[0] >= 0 {
            Darwin.close(inputPipe[0])
            inputPipe[0] = -1
        }
        Darwin.close(outputPipe[1])
        outputPipe[1] = -1
        guard let identity = inspector.identity(for: processIdentifier) else {
            _ = kill(-processIdentifier, SIGKILL)
            _ = kill(processIdentifier, SIGKILL)
            Self.reap(processIdentifier)
            throw SudoPOSIXSpawnError.identityUnavailable
        }
        shouldRemoveOutput = false
        let io = SudoSpawnedProcessIO(
            input: inputPipe[1],
            output: outputPipe[0],
            outputFile: outputDescriptor
        )
        shouldCloseOutput = false
        inputPipe[1] = -1
        outputPipe[0] = -1
        return SudoSpawnedProcess(
            identity: identity,
            processGroupIdentifier: processIdentifier,
            outputURL: command.outputURL,
            standardInput: command.standardInput,
            standardInputReadyMarker: command.standardInputReadyMarker,
            controlMarkers: command.controlMarkers,
            io: io
        )
    }

    private static func configureParentDescriptor(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw SudoPOSIXSpawnError.descriptorFailed(errno)
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw SudoPOSIXSpawnError.descriptorFailed(errno)
        }
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
    case pipeFailed(Int32)
    case descriptorFailed(Int32)
    case outputOpenFailed(Int32)
    case fileActionsFailed(Int32)
    case attributesFailed(Int32)
    case invalidCString
    case allocationFailed
    case spawnFailed(Int32)
    case identityUnavailable
}
