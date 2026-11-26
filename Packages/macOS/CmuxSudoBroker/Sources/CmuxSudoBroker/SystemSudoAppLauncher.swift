import Darwin
import Foundation

struct SystemSudoAppLauncher: SudoAppLaunching {
    private let inspector: any SudoProcessInspecting
    private let signaler: any SudoProcessSignaling

    init(
        inspector: any SudoProcessInspecting,
        signaler: any SudoProcessSignaling
    ) {
        self.inspector = inspector
        self.signaler = signaler
    }

    func launch(appBundleURL: URL) throws {
        var fileActions: posix_spawn_file_actions_t?
        try Self.requireSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let flags = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            let status = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    descriptor,
                    path,
                    flags,
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

        let arguments = ["/usr/bin/open", "-g", "-a", appBundleURL.path]
        let environment = SudoProcessEnvironment().entries
        var processIdentifier: pid_t = 0
        let spawnStatus = try Self.withCStringArray(arguments) { arguments in
            try Self.withCStringArray(environment) { environment in
                "/usr/bin/open".withCString { executable in
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
        try Self.requireSuccess(spawnStatus)
        guard let identity = inspector.identity(for: processIdentifier) else {
            switch Self.reapIfExited(processIdentifier) {
            case .exited(let succeeded):
                guard succeeded else { throw SudoAppLaunchError.openFailed }
                return
            case .running:
                Self.terminateAndReap(processIdentifier)
                throw SudoAppLaunchError.identityUnavailable
            case .unavailable:
                throw SudoAppLaunchError.identityUnavailable
            }
        }

        let waiter = SudoProcessExitWaiter(inspector: inspector)
        let survivors = waiter.survivors(among: [identity], after: 10)
        if !survivors.isEmpty {
            let terminator = SudoProcessTreeTerminator(
                inspector: inspector,
                signaler: signaler
            )
            let cleanupSurvivors = terminator.terminate(root: identity)
            if !cleanupSurvivors.contains(identity) {
                Self.reap(processIdentifier)
            }
            throw SudoAppLaunchError.timedOut
        }

        var waitStatus: Int32 = 0
        var waitResult: pid_t = 0
        repeat {
            waitResult = waitpid(processIdentifier, &waitStatus, 0)
        } while waitResult < 0 && errno == EINTR
        guard waitResult == processIdentifier,
              waitStatus & 0x7f == 0,
              (waitStatus >> 8) & 0xff == 0 else {
            throw SudoAppLaunchError.openFailed
        }
    }

    private static func requireSuccess(_ status: Int32) throws {
        guard status == 0 else { throw SudoAppLaunchError.posix(status) }
    }

    private static func terminateAndReap(_ processIdentifier: Int32) {
        guard processIdentifier > 1 else { return }
        _ = kill(-processIdentifier, SIGKILL)
        _ = kill(processIdentifier, SIGKILL)
        reap(processIdentifier)
    }

    private static func reapIfExited(_ processIdentifier: Int32) -> ImmediateChildState {
        var status: Int32 = 0
        var result: pid_t = 0
        repeat {
            result = waitpid(processIdentifier, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 {
            return .running
        }
        guard result == processIdentifier else {
            return .unavailable
        }
        let succeeded = status & 0x7f == 0 && (status >> 8) & 0xff == 0
        return .exited(succeeded: succeeded)
    }

    private static func reap(_ processIdentifier: Int32) {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
    }

    private static func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw SudoAppLaunchError.allocationFailed
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SudoAppLaunchError.allocationFailed
            }
            return try operation(baseAddress)
        }
    }

    private enum ImmediateChildState {
        case running
        case exited(succeeded: Bool)
        case unavailable
    }
}

private enum SudoAppLaunchError: Error {
    case posix(Int32)
    case allocationFailed
    case identityUnavailable
    case timedOut
    case openFailed
}
