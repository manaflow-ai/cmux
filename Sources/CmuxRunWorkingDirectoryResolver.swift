import Darwin
import Foundation

// Safety: stored state is immutable; FileManager is used only by synchronous
// calls, and the injectable command factory is explicitly @Sendable.
struct CmuxRunWorkingDirectoryResolver: @unchecked Sendable {
    static let defaultResolutionTimeout: Duration = .seconds(5)

    let fileManager: FileManager
    let commandOverride: (@Sendable (String) -> CmuxRunWorkingDirectoryCommand)?
    private let processLimiter: CmuxRunWorkingDirectoryProcessLimiter

    init(
        fileManager: FileManager = .default,
        processLimiter: CmuxRunWorkingDirectoryProcessLimiter = CmuxRunWorkingDirectoryProcessLimiter(),
        commandOverride: (@Sendable (String) -> CmuxRunWorkingDirectoryCommand)? = nil
    ) {
        self.fileManager = fileManager
        self.commandOverride = commandOverride
        self.processLimiter = processLimiter
    }

    func resolve(
        _ requestedPath: String
    ) -> Result<CmuxRunResolvedWorkingDirectory, CmuxRunURLExecutionError> {
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
        return resolvedDirectory(at: resolved)
    }

    func resolveWithDeadline(
        _ requestedPath: String,
        timeout: Duration = defaultResolutionTimeout
    ) async -> Result<CmuxRunResolvedWorkingDirectory, CmuxRunURLExecutionError> {
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
                  let resolvedDirectory = Self.resolvedDirectory(fromVerifierOutput: output) else {
                return .failure(.workingDirectoryNotFound)
            }
            if let error = canonicalPathValidationError(resolvedDirectory.path) {
                return .failure(error)
            }
            return .success(resolvedDirectory)
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

    private func resolvedDirectory(
        at path: String
    ) -> Result<CmuxRunResolvedWorkingDirectory, CmuxRunURLExecutionError> {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            return .failure(.workingDirectoryNotFound)
        }
        return .success(CmuxRunResolvedWorkingDirectory(
            path: path,
            identity: CmuxRunWorkingDirectoryIdentity(
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)
            )
        ))
    }

    static func canonicalDirectoryCommand(
        for expandedPath: String
    ) -> CmuxRunWorkingDirectoryCommand {
        CmuxRunWorkingDirectoryCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "CDPATH= cd -P -- \"$1\" || exit; "
                    + "pwd -P || exit; "
                    + "printf '\\0' || exit; "
                    + "exec /usr/bin/stat -f '%d:%i' .",
                "cmux-run",
                expandedPath
            ]
        )
    }

    private static func resolvedDirectory(
        fromVerifierOutput output: Data
    ) -> CmuxRunResolvedWorkingDirectory? {
        guard output.last == 0x0A,
              let separator = output.firstIndex(of: 0),
              separator > output.startIndex,
              output[output.index(before: separator)] == 0x0A,
              output[output.index(after: separator)..<output.index(before: output.endIndex)]
                .firstIndex(of: 0) == nil else {
            return nil
        }

        let pathData = output[..<output.index(before: separator)]
        let identityData = output[
            output.index(after: separator)..<output.index(before: output.endIndex)
        ]
        guard let path = String(data: pathData, encoding: .utf8),
              (path as NSString).isAbsolutePath,
              let identityText = String(data: identityData, encoding: .utf8) else {
            return nil
        }
        let identityParts = identityText.split(separator: ":", omittingEmptySubsequences: false)
        guard identityParts.count == 2,
              let device = UInt64(identityParts[0]),
              let inode = UInt64(identityParts[1]) else {
            return nil
        }
        return CmuxRunResolvedWorkingDirectory(
            path: path,
            identity: CmuxRunWorkingDirectoryIdentity(device: device, inode: inode)
        )
    }

}
