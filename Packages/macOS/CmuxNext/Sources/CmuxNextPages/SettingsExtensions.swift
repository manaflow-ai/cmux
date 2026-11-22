public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups

/// Settings > Advanced > Extensions (webviews `ExtensionsCard.tsx`, extensions DESIGN.md section 14
/// step 2): `cmux.settings.extensions.run {verb}` runs the bundled CLI and answers its JSON.
/// `meters` is `cmux --json apps meters` (the daemon's `apps.meters`: one row per installed
/// extension with its budget step, host and batches); `status`, `start`, `good`, `bad` and `reset`
/// are `cmux --json safe-mode bisect VERB` (the daemon's `safe_mode.bisect`). The meter and the
/// bisect are the daemon's (cmux-tui-core apps/meters.rs, apps/safe_mode_bisect.rs), so the card
/// and the CLI never differ, and this type keeps no state.
///
/// `meters` and `status` only read. A bisect step changes which extensions run, so it runs only on
/// the person's click or key in the page or a call they approved: a page script alone gets
/// `cmux.app.user_only`. A refusal is the CLI's words on stderr, answered as `{code, message}`.
@MainActor
public final class SettingsExtensions: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.extensions.run"
    /// The bisect steps that change what runs.
    nonisolated static let changes: Set<String> = ["start", "good", "bad", "reset"]
    nonisolated static let timeout: Duration = .seconds(30)

    /// One CLI run: arguments in, exit status, stdout and stderr out.
    public typealias Runner = @Sendable (URL, [String]) async throws -> (Int32, Data, Data)

    private let cli: @MainActor () async -> URL?
    private let runCLI: Runner

    public init(cli: @escaping @MainActor () async -> URL?, runCLI: @escaping Runner) {
        self.cli = cli
        self.runCLI = runCLI
    }

    /// The app's: the bundled CLI run as a child process.
    public convenience init(cli: @escaping @MainActor () async -> URL?) {
        self.init(cli: cli, runCLI: { try await SettingsExtensions.run($0, $1) })
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        let verb = params["verb"]?.stringValue ?? ""
        let arguments = try Self.arguments(verb)
        if Self.changes.contains(verb) {
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(verb) needs a click in the page")
            }
        }
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let (status, stdout, stderr) = try await runCLI(binary, arguments)
        if status == 0 { return (try? JSONValue.parse(stdout)) ?? .object([:]) }
        return Self.refusal(stderr)
    }

    /// The CLI's words for one verb.
    nonisolated static func arguments(_ verb: String) throws -> [String] {
        switch verb {
        case "meters": return ["--json", "apps", "meters"]
        case "status", "start", "good", "bad", "reset": return ["--json", "safe-mode", "bisect", verb]
        default: throw PageError.invalidParams("verb is meters, status, start, good, bad or reset")
        }
    }

    /// `cmux: CODE: MESSAGE` (or `cmux: MESSAGE`) on stderr as `{code, message}`.
    nonisolated static func refusal(_ stderr: Data) -> JSONValue {
        var text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("cmux: ") { text.removeFirst("cmux: ".count) }
        let parts = text.split(separator: ":", maxSplits: 1)
        if parts.count == 2, !parts[0].contains(" ") {
            return ["code": .string(String(parts[0])), "message": .string(parts[1].trimmingCharacters(in: .whitespaces))]
        }
        return ["code": "cmux.settings.extensions", "message": .string(text)]
    }

    /// The bundled CLI, off the main actor, with a deadline; a step runs to its end even when the
    /// page goes away, so the daemon's bisect never misses an answer the person gave.
    @concurrent public nonisolated static func run(_ cli: URL, _ arguments: [String]) async throws -> (Int32, Data, Data) {
        let request = ProcessRequest(cli, arguments, environment: ProcessInfo.processInfo.environment, errorOutput: .separate,
                                     timeout: timeout, onCancel: .finish)
        let outcome = try await AsyncProcess().run(request)
        return (outcome.succeeded ? 0 : max(outcome.status, 1), outcome.output, outcome.errorOutput)
    }
}
