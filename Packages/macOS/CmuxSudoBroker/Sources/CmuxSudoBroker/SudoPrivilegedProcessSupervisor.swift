import Darwin
import Foundation

/// Spawns and reaps the approved root shell under a root-owned deadline.
struct SudoPrivilegedProcessSupervisor: Sendable {
    static let sourceCommand = "source /dev/fd/4"
    private let inspector: any SudoProcessInspecting
    private let inventory: SudoOrphanProcessInventory
    private let terminator: SudoProcessTreeTerminator
    private let exitWaiter: SudoProcessExitWaiter
    private let now: @Sendable () -> Date
    private let preflightNow: @Sendable () -> Date

    init(
        inspector: any SudoProcessInspecting = SystemSudoProcessInspector(),
        signaler: any SudoProcessSignaling = SystemSudoProcessSignaler(),
        now: @Sendable @escaping () -> Date = { .now },
        preflightNow: @Sendable @escaping () -> Date = { .now }
    ) {
        self.inspector = inspector
        inventory = SudoOrphanProcessInventory(inspector: inspector)
        terminator = SudoProcessTreeTerminator(inspector: inspector, signaler: signaler)
        exitWaiter = SudoProcessExitWaiter(inspector: inspector)
        self.now = now
        self.preflightNow = preflightNow
    }

    func execute(
        scriptDescriptor: Int32,
        displayName: String,
        deadline: Date
    ) -> SudoPrivilegedProcessOutcome {
        // Keep preflight on an independent wall clock; execution clocks may coordinate test I/O.
        guard deadline > preflightNow() else { return .timedOut }
        let processIdentifier: Int32
        do {
            processIdentifier = try spawn(
                scriptDescriptor: scriptDescriptor,
                displayName: displayName
            )
        } catch {
            return .launchFailed
        }
        guard awaitInitialSuspension(processIdentifier) else {
            terminateAndReap(processIdentifier)
            return .launchFailed
        }
        guard let identity = inspector.identity(for: processIdentifier) else {
            terminateAndReap(processIdentifier)
            return .launchFailed
        }
        let remainingBeforeResume = deadline.timeIntervalSince(preflightNow())
        guard remainingBeforeResume > 0 else {
            terminateAndReap(processIdentifier)
            return .timedOut
        }
        guard kill(processIdentifier, SIGCONT) == 0 else {
            terminateAndReap(processIdentifier)
            return .launchFailed
        }

        let remaining = max(0, deadline.timeIntervalSince(now()))
        let survivors = exitWaiter.survivors(among: [identity], after: remaining)
        if survivors.isEmpty {
            guard let groupIdentities = identities(inProcessGroup: processIdentifier) else {
                _ = terminator.terminate(root: identity)
                return .cleanupFailed
            }
            let cleanupSurvivors = terminator.terminate(roots: groupIdentities)
            let outcome = reapOutcome(processIdentifier)
            guard cleanupSurvivors.isEmpty else { return .cleanupFailed }
            let detached = inventory.identitiesByScriptPath(
                approvedScriptURLs: [URL(fileURLWithPath: displayName)]
            )[URL(fileURLWithPath: displayName).standardizedFileURL.path] ?? []
            guard detached.isEmpty else {
                // The process group is the kernel-owned containment boundary.
                // Best-effort argv inventory catches detached broker wrappers;
                // arbitrary setsid daemons remain an explicit platform boundary.
                _ = terminator.terminate(roots: detached)
                return .cleanupFailed
            }
            return outcome
        }

        let cleanupSurvivors = terminator.terminate(root: identity)
        _ = reap(processIdentifier, options: WNOHANG)
        return cleanupSurvivors.isEmpty ? .timedOut : .cleanupFailed
    }

    private func identities(inProcessGroup group: Int32) -> [SudoProcessIdentity]? {
        guard var processIdentifiers = inspector.processIdentifiers(inProcessGroup: group) else {
            return nil
        }
        // Include the known root even when a successful group listing omits it.
        processIdentifiers.append(group)
        return Set(processIdentifiers).compactMap { processIdentifier in
            guard let initialIdentity = inspector.identity(for: processIdentifier),
                  inspector.processGroupIdentifier(for: processIdentifier) == group,
                  let finalIdentity = inspector.identity(for: processIdentifier),
                  initialIdentity == finalIdentity,
                  inspector.processGroupIdentifier(for: processIdentifier) == group else {
                return nil
            }
            return finalIdentity
        }
    }

    private func spawn(
        scriptDescriptor: Int32,
        displayName: String
    ) throws -> Int32 {
        var fileActions: posix_spawn_file_actions_t?
        try requireSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try requireSuccess(
                posix_spawn_file_actions_addinherit_np(&fileActions, descriptor)
            )
        }
        try requireSuccess(
            posix_spawn_file_actions_adddup2(&fileActions, scriptDescriptor, 4)
        )
        if scriptDescriptor != 4 {
            try requireSuccess(
                posix_spawn_file_actions_addclose(&fileActions, scriptDescriptor)
            )
        }
        var attributes: posix_spawnattr_t?
        try requireSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        try requireSuccess(
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_CLOEXEC_DEFAULT
                        | POSIX_SPAWN_SETPGROUP
                        | POSIX_SPAWN_START_SUSPENDED
                )
            )
        )

        let executable = "/bin/bash"
        let arguments = [executable, "-c", Self.sourceCommand, displayName]
        let environment = SudoProcessEnvironment().entries
        var processIdentifier: Int32 = 0
        let status = try withCStringArray(arguments) { arguments in
            try withCStringArray(environment) { environment in
                executable.withCString { executable in
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
        try requireSuccess(status)
        guard processIdentifier > 1 else { throw Failure.invalidProcessIdentifier }
        return processIdentifier
    }

    private func reapOutcome(_ processIdentifier: Int32) -> SudoPrivilegedProcessOutcome {
        guard let status = reap(processIdentifier, options: 0) else {
            return .launchFailed
        }
        let signal = status & 0x7f
        return signal == 0
            ? .exited((status >> 8) & 0xff)
            : .signaled(signal)
    }

    private func awaitInitialSuspension(_ processIdentifier: Int32) -> Bool {
        var status: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(processIdentifier, &status, WUNTRACED)
        } while result < 0 && errno == EINTR
        return result == processIdentifier
            && status & 0x7f == 0x7f
    }

    private func terminateAndReap(_ processIdentifier: Int32) {
        _ = kill(-processIdentifier, SIGKILL)
        _ = kill(processIdentifier, SIGKILL)
        _ = reap(processIdentifier, options: 0)
    }

    private func reap(_ processIdentifier: Int32, options: Int32) -> Int32? {
        var status: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(processIdentifier, &status, options)
        } while result < 0 && errno == EINTR
        return result == processIdentifier ? status : nil
    }

    private func requireSuccess(_ status: Int32) throws {
        guard status == 0 else { throw Failure.posix(status) }
    }

    private func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw Failure.allocation
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw Failure.allocation }
            return try operation(baseAddress)
        }
    }

    private enum Failure: Error {
        case posix(Int32)
        case invalidProcessIdentifier
        case allocation
    }
}
