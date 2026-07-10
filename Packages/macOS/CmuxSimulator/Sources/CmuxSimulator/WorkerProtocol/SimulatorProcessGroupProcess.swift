import Darwin
import Foundation

/// A subprocess launched with an explicit process-group ownership policy.
///
/// `Foundation.Process` does not expose `POSIX_SPAWN_SETPGROUP`. Simulator
/// host commands own dedicated groups so command-local cancellation reaches
/// descendants. Worker commands inherit the worker group so a worker crash or
/// host cleanup cannot strand helpers outside the worker's lifecycle boundary.
package final class SimulatorProcessGroupProcess: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var isRunning = true
        var terminationStatus: Int32?
        var terminationHandler: (@Sendable (Int32) -> Void)?
    }

    package let processIdentifier: Int32

    private let hostProcessGroupIdentifier: Int32
    private let launchGrouping: SimulatorProcessLaunchGrouping
    private let state = State()

    private init(
        processIdentifier: Int32,
        launchGrouping: SimulatorProcessLaunchGrouping
    ) {
        self.processIdentifier = processIdentifier
        self.launchGrouping = launchGrouping
        hostProcessGroupIdentifier = getpgrp()
        startReaper()
    }

    deinit {
        guard isRunning else { return }
        signalOwnedScope(SIGKILL)
    }

    package var isRunning: Bool {
        state.lock.withLock { state.isRunning }
    }

    package var terminationStatus: Int32? {
        state.lock.withLock { state.terminationStatus }
    }

    /// Installs the single leader-termination callback. If the leader already
    /// exited, the callback runs immediately with its decoded status.
    package func setTerminationHandler(
        _ handler: @escaping @Sendable (Int32) -> Void
    ) {
        let completedStatus = state.lock.withLock { () -> Int32? in
            if let terminationStatus = state.terminationStatus {
                return terminationStatus
            }
            state.terminationHandler = handler
            return nil
        }
        if let completedStatus { handler(completedStatus) }
    }

    /// Signals the scope owned by this wrapper.
    ///
    /// Dedicated launches signal the complete command group. Inherited launches
    /// signal only the direct child because their group also contains the worker
    /// and its unrelated commands.
    @discardableResult
    package func signalOwnedScope(_ signal: Int32) -> Bool {
        guard state.lock.withLock({ state.isRunning }) else { return false }
        switch launchGrouping {
        case .dedicatedProcessGroup:
            if SimulatorWorkerProcessGroup.signal(
                signal,
                groupIdentifier: processIdentifier,
                hostGroupIdentifier: hostProcessGroupIdentifier
            ) {
                return true
            }
            return Darwin.kill(processIdentifier, signal) == 0
        case .inheritedProcessGroup:
            return Darwin.kill(processIdentifier, signal) == 0
        }
    }

    package func interrupt() {
        _ = signalOwnedScope(SIGINT)
    }

    package func terminate() {
        _ = signalOwnedScope(SIGTERM)
    }

    package func forceKill() {
        _ = signalOwnedScope(SIGKILL)
    }

    /// Launches an executable with the requested process-group ownership.
    ///
    /// Standard input is always `/dev/null`; absent output descriptors are also
    /// redirected to `/dev/null`.
    package static func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        standardOutputFD: Int32? = nil,
        standardErrorFD: Int32? = nil,
        fileDescriptorsToClose: [Int32] = [],
        grouping: SimulatorProcessLaunchGrouping
    ) throws -> SimulatorProcessGroupProcess {
        var fileActions: posix_spawn_file_actions_t?
        try throwPOSIXErrorIfNeeded(
            posix_spawn_file_actions_init(&fileActions)
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try "/dev/null".withCString { path in
            try throwPOSIXErrorIfNeeded(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            )
        }
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
        if grouping == .dedicatedProcessGroup {
            try throwPOSIXErrorIfNeeded(
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            )
            try throwPOSIXErrorIfNeeded(posix_spawnattr_setpgroup(&attributes, 0))
        }

        var mergedEnvironment = ProcessInfo.processInfo.environment
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
        guard processIdentifier > 1 else {
            throw POSIXError(.ECHILD)
        }
        return SimulatorProcessGroupProcess(
            processIdentifier: processIdentifier,
            launchGrouping: grouping
        )
    }

    private func startReaper() {
        let processIdentifier = self.processIdentifier
        let hostProcessGroupIdentifier = self.hostProcessGroupIdentifier
        let launchGrouping = self.launchGrouping
        let state = self.state
        let thread = Thread {
            var rawStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(processIdentifier, &rawStatus, 0)
            } while waitResult == -1 && errno == EINTR

            let status = waitResult == processIdentifier
                ? Self.decodedTerminationStatus(rawStatus)
                : -1
            let handler = state.lock.withLock { () -> (@Sendable (Int32) -> Void)? in
                state.isRunning = false
                state.terminationStatus = status
                let handler = state.terminationHandler
                state.terminationHandler = nil
                return handler
            }

            if launchGrouping == .dedicatedProcessGroup {
                // The leader is reaped, but descendants may still retain pipes
                // or ignore an earlier signal. This group is exclusively ours.
                _ = SimulatorWorkerProcessGroup.signal(
                    SIGKILL,
                    groupIdentifier: processIdentifier,
                    hostGroupIdentifier: hostProcessGroupIdentifier
                )
            }
            handler?(status)
        }
        thread.name = "cmux-simulator-process-reaper"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private static func configureOutput(
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
                try throwPOSIXErrorIfNeeded(
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        target,
                        path,
                        O_WRONLY,
                        0
                    )
                )
            }
        }
    }

    private static func withMutableCStringArray<Result>(
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
            for pointer in pointers.dropLast() {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            return try body(baseAddress)
        }
    }

    private static func throwPOSIXErrorIfNeeded(_ status: Int32) throws {
        guard status != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
    }

    private static func decodedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let terminatingSignal = rawStatus & 0x7f
        if terminatingSignal == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return terminatingSignal
    }
}
