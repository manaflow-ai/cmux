public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
// Only the runner: CmuxNextDaemon has a JSONValue of its own, and this file speaks the page's.
import struct CmuxNextDaemon.ProcessRunner

/// Settings' try-on bar (webviews `TryOnBar.tsx`): `cmux.settings.customize.run {verb}` runs
/// `cmux --json customize VERB` for `status`, `keep` or `revert` through the bundled CLI and answers
/// its JSON, or an error's envelope on a refusal. The engine is the CLI's (cmux-customize
/// `try_on.rs`), so the bar and the CLI never differ, and nothing here keeps a clock.
@MainActor
public final class CustomizeTryOnPage: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.customize.run"
    /// The verbs the page may run.
    public static let verbs: Set<String> = ["status", "keep", "revert"]

    private let cli: @MainActor () async -> URL?
    private let runCLI: @Sendable (URL, [String]) async throws -> (Int32, Data, Data)

    public init(cli: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String]) async throws -> (Int32, Data, Data) = CustomizeTryOnPage.run) {
        self.cli = cli
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard let verb = params["verb"]?.stringValue, Self.verbs.contains(verb) else {
            throw PageError.invalidParams("verb is status, keep or revert")
        }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let (status, stdout, stderr) = try await runCLI(cli, ["--json", "customize", verb])
        return (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
    }

    /// The bundled CLI, off the main actor, with the agent-integrations card's deadline (a status is a few file reads).
    @concurrent public nonisolated static func run(_ cli: URL, _ arguments: [String]) async throws -> (Int32, Data, Data) {
        let ran = try await ProcessRunner.run(executable: cli, arguments: arguments, environment: nil,
                                              timeout: .seconds(60), clock: ContinuousClock())
        return (ran.status, ran.stdout, ran.stderr)
    }
}
