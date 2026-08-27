import Darwin
import Foundation
import os

/// Gives a cancellation handler a Sendable way to terminate a spawned helper
/// process without capturing Foundation's `Process` object in a concurrent
/// closure.
final class NotificationSoundProcessCancellation: @unchecked Sendable {
    private struct State: Sendable {
        var processIdentifier: pid_t?
        var cancellationRequested = false
        var finished = false
    }

    // Safety: this lock is only a short compare-and-set for the process handle
    // shared by the synchronous spawn/cancellation callbacks. Process lifetime
    // and all mutable staging state remain owned by the async caller/actor.
    private let state = OSAllocatedUnfairLock(initialState: State(processIdentifier: nil))

    /// Registers the child before it is resumed, returning whether it may run.
    func register(processIdentifier: pid_t) -> Bool {
        let shouldResume = state.withLock { state in
            state.processIdentifier = processIdentifier
            return !state.cancellationRequested && !state.finished
        }
        if !shouldResume {
            terminate(processIdentifier: processIdentifier)
        }
        return shouldResume
    }

    /// Marks a reaped child so a late cancellation cannot signal a recycled PID.
    func markFinished() {
        state.withLock { state in
            state.finished = true
            state.processIdentifier = nil
        }
    }

    func cancel() {
        let processID = state.withLock { state -> pid_t? in
            state.cancellationRequested = true
            guard !state.finished else { return nil }
            return state.processIdentifier
        }
        if let processID {
            terminate(processIdentifier: processID)
        }
    }

    private func terminate(processIdentifier: pid_t) {
        guard processIdentifier > 1 else { return }
        let groupResult = Darwin.kill(-processIdentifier, SIGTERM)
        let groupError = errno
        // The child was spawned with POSIX_SPAWN_SETPGROUP, so descendants
        // inherit this group before they can execute. Escalate immediately to
        // keep cancellation bounded even when a shell ignores SIGTERM.
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        if groupResult == -1, groupError == ESRCH {
            // Defensive fallback for a platform/runtime that reaped the group
            // before the signal arrived; never leave the leader un-reaped.
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

/// Drains a conversion pipe on the process-I/O bridge while retaining only
/// bounded diagnostic output. The Foundation handle is confined to this reader.
private final class NotificationSoundErrorPipeReader: @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readCapped(maxBytes: Int) -> Data {
        var captured = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            guard !chunk.isEmpty else { break }
            if captured.count < maxBytes {
                captured.append(
                    chunk.prefix(maxBytes - captured.count)
                )
            }
        }
        return captured
    }
}

/// Runs `afconvert` without blocking the caller's executor.
struct NotificationSoundProcessRunner: NotificationSoundProcessRunning, Sendable {
    private static let maximumErrorOutputBytes = 64 * 1024
    private static let defaultExecutableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    private static let defaultTimeoutNanoseconds: UInt64 = 30_000_000_000
    // FileHandle reads and waitpid are intentionally bridged to a private GCD
    // queue. They can block until a child or descendant closes a descriptor;
    // running them in Task.detached would consume Swift's cooperative workers
    // and starve the deadline task that is responsible for cancellation.
    private static let blockingIOQueue = DispatchQueue(
        label: "com.cmuxterm.notification-sound.process-io",
        qos: .utility,
        attributes: .concurrent
    )

    struct Result: Sendable {
        let terminationStatus: Int32
        let errorOutput: String?
    }

    private enum ProcessWaitResult: Sendable {
        case success(Int32)
        case failure(Int32)
    }

    private let executableURL: URL
    private let timeoutNanoseconds: UInt64
    private let argumentBuilder: @Sendable (URL, URL) -> [String]
    /// Custom notification commands historically discarded stderr. Keep that
    /// contract explicit so a background descendant cannot retain the
    /// conversion diagnostic pipe after its shell exits.
    private let capturesErrorOutput: Bool

    init(
        executableURL: URL = defaultExecutableURL,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        argumentBuilder: @escaping @Sendable (URL, URL) -> [String] = { sourceURL, destinationURL in
            [
                "-f", "caff",
                "-d", "LEI16",
                sourceURL.standardizedFileURL.path,
                destinationURL.standardizedFileURL.path,
            ]
        },
        capturesErrorOutput: Bool = true
    ) {
        self.executableURL = executableURL
        self.timeoutNanoseconds = timeoutNanoseconds
        self.argumentBuilder = argumentBuilder
        self.capturesErrorOutput = capturesErrorOutput
    }

    func run(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws -> Result {
        try await run(
            arguments: argumentBuilder(sourceURL, destinationURL),
            environment: nil
        )
    }

    /// Runs an arbitrary command through the same process-group and deadline
    /// machinery used by `afconvert`.
    func run(
        arguments: [String],
        environment: [String: String]?
    ) async throws -> Result {
        let cancellation = NotificationSoundProcessCancellation()
        do {
            return try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler(
                        operation: {
                            try await runProcess(
                                arguments: [executableURL.path] + arguments,
                                environment: environment,
                                cancellation: cancellation,
                                capturesErrorOutput: capturesErrorOutput
                            )
                        },
                        onCancel: {
                            cancellation.cancel()
                        }
                    )
                }
                group.addTask {
                    let boundedNanoseconds = min(
                        timeoutNanoseconds,
                        UInt64(Int64.max)
                    )
                    // Genuine external-process deadline; cancellation kills
                    // the entire private process group and then reaps it.
                    try await ContinuousClock().sleep(
                        for: .nanoseconds(Int64(boundedNanoseconds))
                    )
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return result
            }
        } catch {
            cancellation.cancel()
            throw error
        }
    }

    private func runProcess(
        arguments: [String],
        environment: [String: String]?,
        cancellation: NotificationSoundProcessCancellation,
        capturesErrorOutput: Bool
    ) async throws -> Result {
        try Task.checkCancellation()

        var pipeDescriptors: [Int32] = [-1, -1]
        guard pipe(&pipeDescriptors) == 0 else {
            throw Self.processError(code: errno, operation: "pipe")
        }
        guard pipeDescriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            pipeDescriptors.forEach { descriptor in
                if descriptor >= 0 { Darwin.close(descriptor) }
            }
            throw Self.processError(code: EINVAL, operation: "pipe descriptors")
        }

        let errorReader = NotificationSoundErrorPipeReader(
            handle: FileHandle(
                fileDescriptor: pipeDescriptors[0],
                closeOnDealloc: false
            )
        )
        let errorReaderTask = Task {
            await Self.readErrorOutput(errorReader)
        }

        let processIdentifier: pid_t
        do {
            processIdentifier = try spawnProcess(
                arguments: arguments,
                environment: environment,
                errorFileDescriptor: pipeDescriptors[1],
                discardErrorOutput: !capturesErrorOutput
            )
        } catch {
            Darwin.close(pipeDescriptors[1])
            _ = await errorReaderTask.value
            closeReadDescriptor(&pipeDescriptors)
            throw error
        }
        // The parent must close its writer after spawn; otherwise the reader
        // cannot observe EOF after the process group exits.
        Darwin.close(pipeDescriptors[1])
        pipeDescriptors[1] = -1

        // Start waiting before registering/resuming. If cancellation was
        // already requested, registration kills the still-suspended child and
        // this single waiter still owns the required reap.
        let terminationTask: Task<Int32, Error> = Task {
            switch await Self.waitForProcess(processIdentifier) {
            case .success(let terminationStatus):
                return terminationStatus
            case .failure(let waitError):
                throw Self.processError(code: waitError, operation: "waitpid")
            }
        }

        guard cancellation.register(processIdentifier: processIdentifier) else {
            cancellation.cancel()
            _ = await terminationTask.result
            _ = await errorReaderTask.value
            closeReadDescriptor(&pipeDescriptors)
            throw CancellationError()
        }

        let continueResult = Darwin.kill(processIdentifier, SIGCONT)
        if continueResult != 0 {
            let continueError = errno
            cancellation.cancel()
            _ = await terminationTask.result
            _ = await errorReaderTask.value
            closeReadDescriptor(&pipeDescriptors)
            if Task.isCancelled { throw CancellationError() }
            throw Self.processError(code: continueError, operation: "SIGCONT")
        }

        let terminationStatus: Int32
        do {
            terminationStatus = try await terminationTask.value
        } catch {
            cancellation.cancel()
            _ = await errorReaderTask.value
            closeReadDescriptor(&pipeDescriptors)
            throw error
        }
        cancellation.markFinished()
        let errorData = await errorReaderTask.value
        closeReadDescriptor(&pipeDescriptors)
        try Task.checkCancellation()
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            terminationStatus: terminationStatus,
            errorOutput: errorOutput.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func spawnProcess(
        arguments: [String],
        environment: [String: String]?,
        errorFileDescriptor: Int32,
        discardErrorOutput: Bool
    ) throws -> pid_t {
        guard !arguments.isEmpty,
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw Self.processError(code: EINVAL, operation: "arguments")
        }
        guard errorFileDescriptor > STDERR_FILENO else {
            throw Self.processError(code: EINVAL, operation: "stderr descriptor")
        }

        var fileActions: posix_spawn_file_actions_t?
        var setupStatus = posix_spawn_file_actions_init(&fileActions)
        guard setupStatus == 0 else {
            throw Self.processError(code: setupStatus, operation: "file actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupStatus = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                $0,
                O_RDONLY,
                0
            )
        }
        if setupStatus == 0 {
            setupStatus = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDOUT_FILENO,
                    $0,
                    O_WRONLY,
                    0
                )
            }
        }
        if setupStatus == 0 {
            if discardErrorOutput {
                // Keep custom-command stderr at the historical null device.
                // Closing the diagnostic pipe in the child is important: a
                // background shell descendant must not keep the reader alive.
                setupStatus = "/dev/null".withCString {
                    posix_spawn_file_actions_addopen(
                        &fileActions,
                        STDERR_FILENO,
                        $0,
                        O_WRONLY,
                        0
                    )
                }
                if setupStatus == 0 {
                    setupStatus = posix_spawn_file_actions_addclose(
                        &fileActions,
                        errorFileDescriptor
                    )
                }
            } else {
                setupStatus = posix_spawn_file_actions_adddup2(
                    &fileActions,
                    errorFileDescriptor,
                    STDERR_FILENO
                )
                if setupStatus == 0 {
                    setupStatus = posix_spawn_file_actions_addclose(
                        &fileActions,
                        errorFileDescriptor
                    )
                }
            }
        }
        guard setupStatus == 0 else {
            throw Self.processError(code: setupStatus, operation: "file actions")
        }

        var attributes: posix_spawnattr_t?
        setupStatus = posix_spawnattr_init(&attributes)
        guard setupStatus == 0 else {
            throw Self.processError(code: setupStatus, operation: "spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // The child starts stopped with its own process group already assigned;
        // this closes the fork/exec window in which shell descendants could
        // escape a post-launch setpgid call. The caller sends SIGCONT only after
        // installing cancellation ownership and the waitpid owner.
        let spawnFlags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
        )
        setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        if setupStatus == 0 {
            setupStatus = posix_spawnattr_setflags(&attributes, spawnFlags)
        }
        guard setupStatus == 0 else {
            throw Self.processError(code: setupStatus, operation: "spawn attributes")
        }

        var argumentPointers = arguments.map { strdup($0) }
        defer {
            for pointer in argumentPointers where pointer != nil {
                free(pointer)
            }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }) else {
            throw Self.processError(code: ENOMEM, operation: "argv allocation")
        }
        argumentPointers.append(nil)

        var environmentPointers: [UnsafeMutablePointer<CChar>?] = []
        if let environment {
            let entries = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            guard entries.allSatisfy({ !$0.utf8.contains(0) }) else {
                throw Self.processError(code: EINVAL, operation: "environment")
            }
            environmentPointers = entries.map { strdup($0) }
            guard environmentPointers.allSatisfy({ $0 != nil }) else {
                throw Self.processError(code: ENOMEM, operation: "environment allocation")
            }
            environmentPointers.append(nil)
        }
        defer {
            for pointer in environmentPointers where pointer != nil {
                free(pointer)
            }
        }

        var processIdentifier: pid_t = 0
        let spawnStatus = arguments[0].withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                if environment == nil {
                    guard let argumentBase = argumentBuffer.baseAddress else {
                        return Int32(EINVAL)
                    }
                    return posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentBase,
                        environ
                    )
                }
                return environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    guard let argumentBase = argumentBuffer.baseAddress,
                          let environmentBase = environmentBuffer.baseAddress else {
                        return Int32(EINVAL)
                    }
                    return posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentBase,
                        environmentBase
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else {
            throw Self.processError(
                code: spawnStatus == 0 ? ECHILD : spawnStatus,
                operation: "posix_spawn"
            )
        }
        return processIdentifier
    }

    private func closeReadDescriptor(_ descriptors: inout [Int32]) {
        guard let index = descriptors.firstIndex(where: { $0 >= 0 }) else { return }
        Darwin.close(descriptors[index])
        descriptors[index] = -1
    }

    private static func readErrorOutput(
        _ reader: NotificationSoundErrorPipeReader
    ) async -> Data {
        await withCheckedContinuation { continuation in
            blockingIOQueue.async {
                continuation.resume(
                    returning: reader.readCapped(maxBytes: maximumErrorOutputBytes)
                )
            }
        }
    }

    private static func waitForProcess(
        _ processIdentifier: pid_t
    ) async -> ProcessWaitResult {
        await withCheckedContinuation { continuation in
            blockingIOQueue.async {
                var rawStatus: Int32 = 0
                var waitResult: pid_t
                repeat {
                    waitResult = waitpid(processIdentifier, &rawStatus, 0)
                } while waitResult == -1 && errno == EINTR
                guard waitResult == processIdentifier else {
                    let waitError = errno
                    continuation.resume(returning: .failure(waitError))
                    return
                }
                let terminationStatus = (rawStatus & 0x7f) == 0
                    ? (rawStatus >> 8) & 0xff
                    : rawStatus & 0x7f
                continuation.resume(returning: .success(terminationStatus))
            }
        }
    }

    private static func processError(code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: operation + " failed (" + String(code) + ")"
            ]
        )
    }
}

/// Shared notification-sound staging facade.
///
/// Every operation that can create, replace, transcode, or inspect a managed
/// staging artifact is routed through one ``NotificationSoundStager`` actor.
/// This keeps the global picker and sparse per-agent matrix on the same cache
/// and prevents concurrent selections from replacing the same destination.
extension NotificationSoundSettings {
    static let customSoundBaseName = "cmux-custom-notification-sound"
    static let systemSoundBaseName = "cmux-system-notification-sound"
    static let systemSoundDirectoryURL = URL(
        fileURLWithPath: "/System/Library/Sounds",
        isDirectory: true
    )

    static let supportedCustomSoundExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    nonisolated private static let soundStager = NotificationSoundStager()

    nonisolated enum CustomSoundPreparationIssue: Error, Sendable {
        case emptyPath
        case missingFile(path: String)
        case missingFileExtension(path: String)
        case stagingFailed(path: String, details: String)

        var logMessage: String {
            switch self {
            case .emptyPath:
                return "Notification custom sound path is empty"
            case .missingFile(let path):
                return "Notification custom sound file does not exist: \(path)"
            case .missingFileExtension(let path):
                return "Notification custom sound requires a file extension: \(path)"
            case .stagingFailed(let path, let details):
                return "Failed to stage custom notification sound from \(path): \(details)"
            }
        }
    }

    static func normalizedPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func expandedURL(for rawPath: String) -> URL? {
        guard let normalized = normalizedPath(rawPath) else { return nil }
        return URL(fileURLWithPath: (normalized as NSString).expandingTildeInPath)
    }

    static func soundDirectoryURL(_ override: URL? = nil) -> URL {
        if let override { return override }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    static func stagedName(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stagedName(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedNameIfReady(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stagedNameIfReady(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    static func prepare(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> Result<String, CustomSoundPreparationIssue> {
        await soundStager.prepareCustomSound(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    /// Stages and decodes a picker selection before it is persisted.
    static func validateCustomSoundFileForSelection(
        path: String,
        stagingDirectory: URL? = nil,
        decoder: (@Sendable (URL) -> Bool)? = nil
    ) async -> Bool {
        await soundStager.validateCustomSoundFileForSelection(
            path: path,
            stagingDirectory: stagingDirectory,
            decoder: decoder
        )
    }

    /// Resolves a matrix override and its global fallback through the shared
    /// actor, returning only a playback-ready value to the caller.
    static func prepareNotificationSound(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL? = nil,
        pendingReferenceID: String? = nil
    ) async -> PreparedNotificationSound {
        await soundStager.prepareNotificationSound(
            snapshot: snapshot,
            stagingDirectory: stagingDirectory,
            pendingReferenceID: pendingReferenceID
        )
    }

    static func releasePendingNotificationSound(referenceID: String) async {
        await soundStager.releasePendingArtifactReference(referenceID)
    }

    static func deferPendingNotificationSound(referenceID: String) async {
        await soundStager.deferPendingArtifactReference(referenceID)
    }

    static func stageSystemSound(
        value: String,
        sourceDirectory: URL = systemSoundDirectoryURL,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stageSystemSound(
            value: value,
            allowedValues: Set(systemSounds.map { $0.value }),
            sourceDirectory: sourceDirectory,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedURL(named fileName: String, stagingDirectory: URL? = nil) -> URL {
        soundDirectoryURL(stagingDirectory)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func stagedFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        return supportedCustomSoundExtensions.contains(normalized) ? normalized : "caf"
    }

    static func stagedFileName(
        forSourceURL sourceURL: URL,
        destinationExtension: String
    ) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        return "\(customSoundBaseName)-\(sourceSignature(for: sourceURL)).\(ext)"
    }

    static func systemSoundFileName(for value: String) -> String {
        "\(systemSoundBaseName)-\(value).aiff"
    }
}
