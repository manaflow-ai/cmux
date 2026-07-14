import Foundation

struct CmuxRunWorkingDirectoryResolver: @unchecked Sendable {
    static let defaultResolutionTimeout: Duration = .seconds(5)

    let fileManager: FileManager
    private let resolutionOverride: (@Sendable (String) -> Result<String, CmuxRunURLExecutionError>)?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.resolutionOverride = nil
    }

    init(
        resolveForTesting: @escaping @Sendable (String) -> Result<String, CmuxRunURLExecutionError>
    ) {
        self.fileManager = .default
        self.resolutionOverride = resolveForTesting
    }

    func resolve(_ requestedPath: String) -> Result<String, CmuxRunURLExecutionError> {
        if let resolutionOverride {
            return resolutionOverride(requestedPath)
        }
        guard requestedPath == requestedPath.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .failure(.workingDirectoryContainsSurroundingWhitespace)
        }
        let expanded = (requestedPath as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            return .failure(.workingDirectoryMustBeAbsolute)
        }

        let resolved = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard resolved == resolved.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .failure(.workingDirectoryContainsSurroundingWhitespace)
        }
        guard !CmuxRunURLRequest.containsUnsafeHiddenCharacter(resolved) else {
            return .failure(.workingDirectoryContainsUnsafeCharacters)
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
        let gate = CmuxRunWorkingDirectoryResolutionGate()
        let resolver = self
        _ = Task.detached(priority: .userInitiated) {
            await gate.finish(resolver.resolve(requestedPath))
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                await gate.finish(.failure(.workingDirectoryResolutionTimedOut))
            } catch is CancellationError {
                return
            } catch {
                await gate.finish(.failure(.workingDirectoryResolutionTimedOut))
            }
        }
        let result = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            Task {
                await gate.finish(.failure(.workingDirectoryResolutionTimedOut))
            }
        }
        timeoutTask.cancel()
        return result
    }
}

private actor CmuxRunWorkingDirectoryResolutionGate {
    typealias Resolution = Result<String, CmuxRunURLExecutionError>

    private var resolution: Resolution?
    private var continuation: CheckedContinuation<Resolution, Never>?

    func value() async -> Resolution {
        if let resolution {
            return resolution
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ resolution: Resolution) {
        guard self.resolution == nil else { return }
        self.resolution = resolution
        continuation?.resume(returning: resolution)
        continuation = nil
    }
}
