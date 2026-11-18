import CmuxNextDaemon
import Darwin
public import CmuxNextSettings
public import Foundation

// Apart from SettingsMcpServers.swift: CmuxNextDaemon and CmuxNextSettings both name a `JSONValue`.
extension SettingsMcpServers {
    /// The longest a sign-in runs: the CLI's own sign-in window (20 minutes) and a margin.
    static let signInLimit: Duration = .seconds(25 * 60)

    /// Runs `executable` with `arguments` and `overrides` on the app's environment, off the main actor,
    /// for at most a minute: `(status, stdout, stderr)`.
    @concurrent public nonisolated static func run(_ executable: URL, _ arguments: [String],
                                                   _ overrides: [String: String]) async throws -> (Int32, Data, Data) {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, environment: environment(overrides),
                                                 timeout: .seconds(60), clock: ContinuousClock())
        return (result.status, result.stdout, result.stderr)
    }

    /// The app's environment with `overrides`; nil (inherit it as it is) when there are none.
    nonisolated static func environment(_ overrides: [String: String]) -> [String: String]? {
        overrides.isEmpty ? nil : ProcessInfo.processInfo.environment.merging(overrides) { $1 }
    }

    /// Runs `executable` with `arguments` off the main actor (ProcessRunner) and hands each JSON line
    /// of its stdout to `line` as it comes (a sign-in prints its page first, then waits for the
    /// person). Returns its exit status, -1 when it did not run. Cancelling the caller ends the child.
    @concurrent public nonisolated static func stream(_ executable: URL, _ arguments: [String], _ overrides: [String: String],
                                                      _ line: @escaping @Sendable (CmuxNextSettings.JSONValue) -> Void) async -> Int32 {
        let result = try? await ProcessRunner.run(
            executable: executable, arguments: arguments, environment: environment(overrides), timeout: signInLimit,
            progressIdle: signInLimit,
            stdoutLine: { text in
                if let value = try? CmuxNextSettings.JSONValue.parse(Data(text.utf8)) { line(value) }
            },
            clock: ContinuousClock())
        return result?.status ?? -1
    }

    /// The Chief helper the app ships beside its cmux CLI, when it is there and executable: a build
    /// without it gets nil, which the page shows as `unavailable`. One `access(2)`, off the main actor.
    @concurrent nonisolated static func chief(besideCLI cli: URL?) async -> URL? {
        guard let helper = cli?.deletingLastPathComponent().appending(path: "optchat-chief", directoryHint: .notDirectory)
        else { return nil }
        return Darwin.access(helper.path, X_OK) == 0 ? helper : nil
    }
}
