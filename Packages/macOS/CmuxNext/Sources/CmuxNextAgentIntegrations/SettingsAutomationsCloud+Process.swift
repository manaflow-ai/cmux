import CmuxNextDaemon
public import Foundation

// Apart from SettingsAutomationsCloud.swift: CmuxNextDaemon and CmuxNextSettings both name a `JSONValue`.
extension SettingsAutomationsCloud {
    /// Runs `executable` with `arguments` off the main actor, for at most a minute, with `stdin`
    /// piped to it (an automation spec; never an argument or the environment): `(status, stdout, stderr)`.
    @concurrent public nonisolated static func run(_ executable: URL, _ arguments: [String],
                                                   _ stdin: Data?) async throws -> (Int32, Data, Data) {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                 stdin: stdin, timeout: .seconds(60), clock: ContinuousClock())
        return (result.status, result.stdout, result.stderr)
    }
}
