import Darwin
import Foundation

/// Launches POSIX processes with injected environment state and file actions.
package struct SimulatorPOSIXProcessLauncher: Sendable {
    private let inheritedEnvironment: [String: String]

    package init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.inheritedEnvironment = inheritedEnvironment
    }

    package func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        standardInputFD: Int32?,
        standardOutputFD: Int32?,
        standardErrorFD: Int32?,
        fileDescriptorsToClose: [Int32]
    ) throws -> Int32 {
        var fileActions: posix_spawn_file_actions_t?
        try throwPOSIXErrorIfNeeded(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try configureInput(&fileActions, descriptor: standardInputFD)
        try configureOutput(
            &fileActions,
            descriptor: standardOutputFD,
            target: STDOUT_FILENO
        )
        try configureOutput(
            &fileActions,
            descriptor: standardErrorFD,
            target: STDERR_FILENO
        )
        for descriptor in Set(fileDescriptorsToClose) where descriptor > STDERR_FILENO {
            try throwPOSIXErrorIfNeeded(
                posix_spawn_file_actions_addclose(&fileActions, descriptor)
            )
        }

        if let currentDirectoryURL {
            try currentDirectoryURL.path.withCString { path in
                let status: Int32
                if #available(macOS 26.0, *) {
                    status = posix_spawn_file_actions_addchdir(&fileActions, path)
                } else {
                    status = posix_spawn_file_actions_addchdir_np(&fileActions, path)
                }
                try throwPOSIXErrorIfNeeded(status)
            }
        }

        var attributes: posix_spawnattr_t?
        try throwPOSIXErrorIfNeeded(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        try throwPOSIXErrorIfNeeded(posix_spawnattr_setpgroup(&attributes, 0))
        try throwPOSIXErrorIfNeeded(posix_spawnattr_setflags(&attributes, spawnFlags))

        var mergedEnvironment = inheritedEnvironment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        let environmentStrings = mergedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let executablePath = executableURL.path
        let argumentStrings = [executablePath] + arguments
        var processIdentifier: pid_t = 0
        let spawnStatus = try withMutableCStringArray(argumentStrings) { argumentPointers in
            try withMutableCStringArray(environmentStrings) { environmentPointers in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try throwPOSIXErrorIfNeeded(spawnStatus)
        guard processIdentifier > 1 else { throw POSIXError(.ECHILD) }
        return processIdentifier
    }

    private func configureInput(
        _ fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32?
    ) throws {
        if let descriptor {
            guard descriptor > STDERR_FILENO else { throw POSIXError(.EBADF) }
            try throwPOSIXErrorIfNeeded(
                posix_spawn_file_actions_adddup2(&fileActions, descriptor, STDIN_FILENO)
            )
        } else {
            try "/dev/null".withCString { path in
                try throwPOSIXErrorIfNeeded(posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                ))
            }
        }
    }

    private func configureOutput(
        _ fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32?,
        target: Int32
    ) throws {
        if let descriptor {
            guard descriptor > STDERR_FILENO else { throw POSIXError(.EBADF) }
            try throwPOSIXErrorIfNeeded(
                posix_spawn_file_actions_adddup2(&fileActions, descriptor, target)
            )
        } else {
            try "/dev/null".withCString { path in
                try throwPOSIXErrorIfNeeded(posix_spawn_file_actions_addopen(
                    &fileActions,
                    target,
                    path,
                    O_WRONLY,
                    0
                ))
            }
        }
    }

    private func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }
        var pointers = try strings.map { string -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            return pointer
        }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() { free(pointer) }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            return try body(baseAddress)
        }
    }

    private func throwPOSIXErrorIfNeeded(_ status: Int32) throws {
        guard status != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
    }
}
