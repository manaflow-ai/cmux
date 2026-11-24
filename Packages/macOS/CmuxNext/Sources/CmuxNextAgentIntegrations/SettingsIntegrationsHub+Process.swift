import CmuxNextDaemon
public import Foundation

// Apart from SettingsIntegrationsHub.swift: CmuxNextDaemon and CmuxNextSettings both name a `JSONValue`.
extension SettingsIntegrationsHub {
    /// Runs `executable` with `arguments` off the main actor, for at most a minute, with `stdin`
    /// piped to it (the Stripe key on a link; never an argument or the environment):
    /// `(status, stdout, stderr)`.
    @concurrent public nonisolated static func run(_ executable: URL, _ arguments: [String],
                                                   _ stdin: Data?) async throws -> (Int32, Data, Data) {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                 stdin: stdin, timeout: .seconds(60), clock: ContinuousClock())
        return (result.status, result.stdout, result.stderr)
    }
}
