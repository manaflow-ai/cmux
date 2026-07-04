import Foundation

extension SessionRestorableAgentSnapshot {
    func seedClaudeTranscriptIfNeeded(fileManager: FileManager = .default) {
        guard kind == .claude else { return }
        ClaudeTranscriptSeeder(fileManager: fileManager).seedTranscriptIfNeeded(
            sessionId: sessionId,
            targetWorkingDirectory: workingDirectory,
            sourceWorkingDirectory: launchCommand?.workingDirectory,
            environment: launchCommand?.environment
        )
    }
}
