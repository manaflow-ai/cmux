import CmuxNextDaemon
public import Foundation

// Apart from SettingsAgentIntegrations.swift: CmuxNextDaemon and CmuxNextSettings both name a
// `JSONValue`, and this file needs only the process runner.
extension SettingsAgentIntegrations {
    /// Runs the bundled CLI off the main actor: its exit status, stdout and stderr.
    @concurrent public nonisolated static func run(_ executable: URL, _ arguments: [String]) async throws -> (Int32, Data, Data) {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                 timeout: .seconds(60), clock: ContinuousClock())
        return (result.status, result.stdout, result.stderr)
    }
}
