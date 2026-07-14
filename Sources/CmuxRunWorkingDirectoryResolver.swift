import Darwin
import Foundation

// Safety: stored state is immutable; FileManager is used only by synchronous
// calls, and the injectable command factory is explicitly @Sendable.
struct CmuxRunWorkingDirectoryResolver: @unchecked Sendable {
    static let defaultResolutionTimeout: Duration = .seconds(5)

    let fileManager: FileManager
    private let commandOverride: (@Sendable (String) -> CmuxRunWorkingDirectoryCommand)?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.commandOverride = nil
    }

    init(
        commandForTesting: @escaping @Sendable (String) -> CmuxRunWorkingDirectoryCommand
    ) {
        self.fileManager = .default
        self.commandOverride = commandForTesting
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

        let limiter = CmuxRunWorkingDirectoryProcessLimiter.shared
        guard await limiter.acquire() else {
            return .failure(.busy)
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
                await limiter.release()
                await gate.complete(status: process.terminationStatus, output: output)
            }
        }

        do {
            try process.run()
        } catch {
            await limiter.release()
            return .failure(.workingDirectoryNotFound)
        }

        let terminate: @Sendable () -> Void = {
            guard process.isRunning else { return }
            process.terminate()
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
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
            // The caller's deadline is independent of child cleanup, but the
            // process-wide permit remains held until termination is observed.
            // Releasing here could admit unbounded verifier processes stuck in
            // uninterruptible filesystem I/O.
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
