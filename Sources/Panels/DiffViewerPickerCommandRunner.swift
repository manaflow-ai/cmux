import CmuxFoundation
import Foundation

/// Owns bounded subprocess admission for restored diff-viewer picker routes.
/// Cancelling the caller removes a queued command or propagates into
/// ``CommandRunner``, which terminates an already-running child process.
actor DiffViewerPickerCommandRunner {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let commandRunner: any CommandRunning
    private let executablePath: String?
    private let timeout: TimeInterval
    private let concurrencyLimit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init() {
        commandRunner = CommandRunner()
        executablePath = Self.bundledCLIPath()
        timeout = 15
        concurrencyLimit = 2
    }

    init(
        commandRunner: any CommandRunning,
        executablePath: String?,
        timeout: TimeInterval = 15,
        concurrencyLimit: Int = 2
    ) {
        self.commandRunner = commandRunner
        self.executablePath = executablePath
        self.timeout = timeout
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    /// Runs one bundled CLI picker command after acquiring a bounded permit.
    /// Returns standard output only for a successful, uncancelled invocation.
    func run(arguments: [String]) async -> String? {
        guard let executablePath else { return nil }

        guard await acquirePermit() else { return nil }
        defer { releasePermit() }

        guard !Task.isCancelled else { return nil }
        let result = await commandRunner.run(
            directory: "/",
            executable: executablePath,
            arguments: arguments,
            timeout: timeout
        )
        guard !Task.isCancelled,
              result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            return nil
        }
        return result.stdout
    }

    private func acquirePermit() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeCount < concurrencyLimit {
            activeCount += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func releasePermit() {
        guard activeCount > 0 else { return }
        if waiters.isEmpty {
            activeCount -= 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private static func bundledCLIPath() -> String? {
        if let environmentPath = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"],
           !environmentPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: environmentPath) {
            return environmentPath
        }
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
