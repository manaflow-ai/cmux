import Foundation
import os

/// Runs a bounded number of local config commands without a terminal or focus changes.
actor CmuxBackgroundCommandRunner {
    private var activeCount = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "BackgroundCommand")

    func run(command: String, directory: String, environment: [String: String]) async -> Bool {
        guard activeCount < 16 else {
            logger.error("Background command dropped at the in-flight limit")
            return false
        }
        activeCount += 1
        Task { [self] in
            await execute(command: command, directory: directory, environment: environment)
        }
        return true
    }

    private func execute(command: String, directory: String, environment: [String: String]) async {
        defer { activeCount -= 1 }
        let session = AutomationProcessSession(
            command: command,
            environment: environment,
            workingDirectory: directory,
            inheritsEnvironment: false
        )
        let result = await withTaskCancellationHandler {
            await session.run(timeoutSeconds: 60)
        } onCancel: {
            session.cancel()
        }
        if !result.succeeded {
            logger.error("Background command failed: \(result.detail, privacy: .public)")
        }
    }
}
