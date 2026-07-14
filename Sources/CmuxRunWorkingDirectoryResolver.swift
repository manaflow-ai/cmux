import Foundation

// Safety: stored state is immutable; FileManager is used only by synchronous
// calls, and the injectable command factory is explicitly @Sendable.
struct CmuxRunWorkingDirectoryResolver: @unchecked Sendable {
    static let defaultResolutionTimeout: Duration = .seconds(5)

    let fileManager: FileManager
    private let commandOverride: (@Sendable (String) -> CmuxRunWorkingDirectoryCommand)?
    private let processLimiter: CmuxRunWorkingDirectoryProcessLimiter

    init(
        fileManager: FileManager = .default,
        processLimiter: CmuxRunWorkingDirectoryProcessLimiter = CmuxRunWorkingDirectoryProcessLimiter()
    ) {
        self.fileManager = fileManager
        self.commandOverride = nil
        self.processLimiter = processLimiter
    }

    init(
        commandForTesting: @escaping @Sendable (String) -> CmuxRunWorkingDirectoryCommand,
        processLimiter: CmuxRunWorkingDirectoryProcessLimiter = CmuxRunWorkingDirectoryProcessLimiter()
    ) {
        self.fileManager = .default
        self.commandOverride = commandForTesting
        self.processLimiter = processLimiter
    }

    func resolve(_ requestedPath: String) -> Result<String, CmuxRunURLExecutionError> {
        let expanded: String
        switch validatedExpandedPath(requestedPath) {
        case .success(let path):
            expanded = path
        case .failure(let error):
            return .failure(error)
        }

        let resolved = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if let error = canonicalPathValidationError(resolved) {
            return .failure(error)
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.workingDirectoryNotFound)
        }
        return .success(resolved)
    }

    func resolveWithDeadline(
        _ requestedPath: String,
        timeout: Duration = defaultResolutionTimeout
    ) async -> Result<String, CmuxRunURLExecutionError> {
        let expanded: String
        switch validatedExpandedPath(requestedPath) {
        case .success(let path):
            expanded = path
        case .failure(let error):
            return .failure(error)
        }

        let permit: UUID
        switch await processLimiter.acquire() {
        case .success(let acquiredPermit):
            permit = acquiredPermit
        case .failure(let error):
            return .failure(error)
        }
        let command = commandOverride?(expanded) ?? Self.canonicalDirectoryCommand(for: expanded)
        let process = Process()
        let standardOutput = Pipe()
        let gate = CmuxRunWorkingDirectoryProcessGate()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
            Task {
                await processLimiter.recordTermination(permit)
                await gate.complete(status: process.terminationStatus, output: output)
            }
        }

        do {
            try process.run()
        } catch {
            await processLimiter.recordTermination(permit)
            return .failure(.workingDirectoryNotFound)
        }

        let terminate: @Sendable () -> Void = {
            guard process.isRunning else { return }
            process.terminate()
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: timeout)
                if await gate.requestTimeout() {
                    terminate()
                }
            } catch is CancellationError {
                return
            } catch {
                if await gate.requestTimeout() {
                    terminate()
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            Task {
                if await gate.requestTimeout() {
                    terminate()
                }
            }
        }
        timeoutTask.cancel()

        switch outcome {
        case .timedOut:
            // Preserve the process cap until termination is observed. If the
            // child is stuck in uninterruptible filesystem I/O, later requests
            // receive an explicit recovery message instead of spawning more.
            await processLimiter.markUnavailable(permit)
            return .failure(.workingDirectoryResolutionTimedOut)
        case .completed(let status, let output):
            guard status == EXIT_SUCCESS,
                  output.last == 0x0A,
                  let resolved = String(data: Data(output.dropLast()), encoding: .utf8),
                  (resolved as NSString).isAbsolutePath else {
                return .failure(.workingDirectoryNotFound)
            }
            if let error = canonicalPathValidationError(resolved) {
                return .failure(error)
            }
            return .success(resolved)
        }
    }

    private func validatedExpandedPath(
        _ requestedPath: String
    ) -> Result<String, CmuxRunURLExecutionError> {
        guard requestedPath == requestedPath.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .failure(.workingDirectoryContainsSurroundingWhitespace)
        }
        let expanded = (requestedPath as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            return .failure(.workingDirectoryMustBeAbsolute)
        }
        return .success(expanded)
    }

    private func canonicalPathValidationError(
        _ resolvedPath: String
    ) -> CmuxRunURLExecutionError? {
        guard resolvedPath == resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .workingDirectoryContainsSurroundingWhitespace
        }
        guard !CmuxRunURLRequest.containsUnsafeHiddenCharacter(resolvedPath) else {
            return .workingDirectoryContainsUnsafeCharacters
        }
        return nil
    }

    private static func canonicalDirectoryCommand(
        for expandedPath: String
    ) -> CmuxRunWorkingDirectoryCommand {
        CmuxRunWorkingDirectoryCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "CDPATH= cd -P -- \"$1\" && pwd -P", "cmux-run", expandedPath]
        )
    }

}
