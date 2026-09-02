import Darwin
import Foundation

struct SudoRunnerLauncher: SudoRunnerLaunching {
    private let executableURL: URL
    private let inspector: any SudoProcessInspecting
    private let reaper: SudoChildProcessReaper
    private let temporaryDirectoryURL: URL

    init(
        executableURL: URL,
        inspector: any SudoProcessInspecting,
        reaper: SudoChildProcessReaper = SudoChildProcessReaper(),
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.executableURL = executableURL
        self.inspector = inspector
        self.reaper = reaper
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    @concurrent
    func launch(
        requestID: String,
        reviewedScript: Data,
        manifest: SudoExecutionManifest
    ) async throws -> SudoLaunchedRunner {
        let capability = SudoReviewedScriptCapability(
            bytes: reviewedScript,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestArgument = try encoder.encode(manifest).base64EncodedString()
        return try capability.withDescriptor { descriptor in
            try launch(
                requestID: requestID,
                manifestArgument: manifestArgument,
                capabilityDescriptor: descriptor
            )
        }
    }

    private func launch(
        requestID: String,
        manifestArgument: String,
        capabilityDescriptor: Int32
    ) throws -> SudoLaunchedRunner {
        var fileActions: posix_spawn_file_actions_t?
        try Self.requireSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try Self.requireSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                capabilityDescriptor,
                STDIN_FILENO
            )
        )
        if capabilityDescriptor != STDIN_FILENO {
            try Self.requireSuccess(
                posix_spawn_file_actions_addclose(&fileActions, capabilityDescriptor)
            )
        }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            let status = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    descriptor,
                    path,
                    O_WRONLY,
                    0
                )
            }
            try Self.requireSuccess(status)
        }

        var attributes: posix_spawnattr_t?
        try Self.requireSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        try Self.requireSuccess(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
            )
        )

        let arguments = [
            executableURL.path,
            SudoExecutionRunner.hiddenCommand,
            requestID,
            manifestArgument,
        ]
        let environment = SudoProcessEnvironment().entries
        var processIdentifier: pid_t = 0
        let status = try Self.withCStringArray(arguments) { arguments in
            try Self.withCStringArray(environment) { environment in
                executableURL.path.withCString { executable in
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
        try Self.requireSuccess(status)
        guard processIdentifier > 1,
              inspector.identity(for: processIdentifier) != nil else {
            if processIdentifier > 1 {
                Self.terminateAndReap(processIdentifier)
            }
            throw SudoRunnerLaunchError.identityUnavailable
        }
        let termination = reaper.start(processIdentifier: processIdentifier)
        return SudoLaunchedRunner(termination: termination)
    }

    private static func terminateAndReap(_ processIdentifier: Int32) {
        _ = kill(-processIdentifier, SIGKILL)
        _ = kill(processIdentifier, SIGKILL)
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
    }

    private static func requireSuccess(_ status: Int32) throws {
        guard status == 0 else { throw SudoRunnerLaunchError.posix(status) }
    }

    private static func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw SudoRunnerLaunchError.allocationFailed
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SudoRunnerLaunchError.allocationFailed
            }
            return try operation(baseAddress)
        }
    }
}

private enum SudoRunnerLaunchError: Error {
    case posix(Int32)
    case allocationFailed
    case identityUnavailable
}
