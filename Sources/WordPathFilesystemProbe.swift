import CmuxFoundation
import Foundation

/// Finds the first existing filesystem candidate with directly owned subprocesses.
///
/// A terminal path can point into an unresponsive filesystem. Each filesystem
/// operation runs as the process directly owned by `CommandRunner`, so deadline
/// teardown cannot leave a shell descendant behind. All operations share one
/// wall-clock budget. Timeout, cancellation, malformed output, and launch
/// failure fail closed.
struct WordPathFilesystemProbe: Sendable {
    private static let realpathExecutable = "/bin/realpath"
    private static let testExecutable = "/bin/test"

    private let commands: any CommandRunning
    private let timeout: TimeInterval

    init(
        commands: any CommandRunning = CommandRunner(),
        timeout: TimeInterval = 0.25
    ) {
        self.commands = commands
        self.timeout = timeout
    }

    func firstExistingPath(
        in paths: [String]
    ) async -> (
        index: Int,
        candidatePath: String,
        resolvedPath: String,
        isReadableRegularFile: Bool
    )? {
        guard !paths.isEmpty,
              timeout.isFinite,
              timeout > 0,
              !Task.isCancelled else {
            return nil
        }
        let startedAt = ProcessInfo.processInfo.systemUptime

        for (index, candidatePath) in paths.enumerated() {
            guard let remaining = remainingTimeout(since: startedAt) else { return nil }
            let canonicalization = await commands.run(
                directory: "/",
                executable: Self.realpathExecutable,
                arguments: [candidatePath],
                timeout: remaining
            )
            guard !Task.isCancelled,
                  canonicalization.executionError == nil,
                  !canonicalization.timedOut else {
                return nil
            }
            guard canonicalization.exitStatus == 0 else { continue }
            guard let resolvedPath = canonicalPath(from: canonicalization.stdout) else {
                return nil
            }

            guard let isRegularFile = await evaluateTest(
                "-f",
                path: resolvedPath,
                startedAt: startedAt
            ) else {
                return nil
            }
            let isReadableRegularFile: Bool
            if isRegularFile {
                guard let isReadable = await evaluateTest(
                    "-r",
                    path: resolvedPath,
                    startedAt: startedAt
                ) else {
                    return nil
                }
                isReadableRegularFile = isReadable
            } else {
                isReadableRegularFile = false
            }
            return (
                index,
                candidatePath,
                resolvedPath,
                isReadableRegularFile
            )
        }
        return nil
    }

    private func evaluateTest(
        _ predicate: String,
        path: String,
        startedAt: TimeInterval
    ) async -> Bool? {
        guard let remaining = remainingTimeout(since: startedAt) else { return nil }
        let result = await commands.run(
            directory: "/",
            executable: Self.testExecutable,
            arguments: [predicate, path],
            timeout: remaining
        )
        guard !Task.isCancelled,
              result.executionError == nil,
              !result.timedOut,
              let exitStatus = result.exitStatus else {
            return nil
        }
        switch exitStatus {
        case 0:
            return true
        case 1:
            return false
        default:
            return nil
        }
    }

    private func remainingTimeout(since startedAt: TimeInterval) -> TimeInterval? {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let remaining = timeout - elapsed
        return remaining > 0 ? remaining : nil
    }

    private func canonicalPath(from output: String?) -> String? {
        guard var path = output, path.last == "\n" else { return nil }
        path.removeLast()
        guard path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\0") else {
            return nil
        }
        return path
    }
}
