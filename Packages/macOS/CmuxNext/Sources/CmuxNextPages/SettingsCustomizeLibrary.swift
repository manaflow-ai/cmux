public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups

/// Settings > Personalization > Customization Library (webviews `CustomizeLibraryCard.tsx`):
/// `cmux.settings.customize.library {verb, name?, position?}` runs `cmux --json customize library
/// VERB …` through the bundled CLI and answers its JSON, or its error envelope on a refusal (a
/// toggle while a preview is open). The library is the CLI's (cmux-customize `library.rs`): what
/// is kept, the stack's order and the rule that the higher entry that is on wins, so the card and
/// the CLI never differ, and this type keeps no state.
///
/// `list` only reads, so the page may ask for it; `on`, `off`, `order` and `remove` rewrite the
/// person's settings and files, so they run only on the person's click or key in the page
/// (`context.userGesture`, the host's record) or a call they approved, as Agent integrations'
/// installs do: a page script alone gets `cmux.app.user_only`.
@MainActor
public final class SettingsCustomizeLibrary: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.customize.library"
    /// The verbs that change the library.
    nonisolated static let changes: Set<String> = ["on", "off", "order", "remove"]
    nonisolated static let timeout: Duration = .seconds(60)

    /// One CLI run: arguments in, exit status, stdout and stderr out.
    public typealias Runner = @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: Runner

    /// `settingsFile` points the CLI at the settings file the app reads (`CMUX_NEXT_CONFIG_FILE`), as
    /// Open Theme File does; nil keeps the CLI's own default.
    public init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL? = { nil },
                runCLI: @escaping Runner = SettingsCustomizeLibrary.run) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        let arguments = try Self.arguments(params)
        if let verb = arguments.dropFirst(3).first, Self.changes.contains(verb) {
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(verb) needs a click in the page")
            }
        }
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        var environment = ProcessInfo.processInfo.environment
        if let file = settingsFile() { environment["CMUX_NEXT_CONFIG_FILE"] = file.path }
        let (status, stdout, stderr) = try await runCLI(binary, arguments, environment)
        // A refusal is the CLI's envelope on stderr (`code`, `message`): the page shows its words.
        return (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
    }

    /// The CLI's words for one page call: `--json customize library VERB [NAME [POSITION]]`. A name
    /// is an argument of its own, never a flag (the CLI refuses a name starting with `-` too).
    nonisolated static func arguments(_ params: JSONValue) throws -> [String] {
        let verb = params["verb"]?.stringValue ?? ""
        let base = ["--json", "customize", "library"]
        switch verb {
        case "list":
            return base + ["list"]
        case "on", "off", "remove", "order":
            guard let name = params["name"]?.stringValue, !name.isEmpty, !name.hasPrefix("-") else {
                throw PageError.invalidParams("name is a library entry")
            }
            guard verb == "order" else { return base + [verb, name] }
            guard let position = params["position"]?.stringValue, isPosition(position) else {
                throw PageError.invalidParams("position is top, bottom or a number from 1")
            }
            return base + [verb, name, position]
        default:
            throw PageError.invalidParams("verb is list, on, off, order or remove")
        }
    }

    nonisolated static func isPosition(_ text: String) -> Bool {
        if text == "top" || text == "bottom" { return true }
        guard (1...6).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return Int(text).map { $0 >= 1 } ?? false
    }

    /// The bundled CLI, off the main actor, with a deadline; a change runs to its end even when the
    /// page goes away, so the library is never left half written by a closed page.
    @concurrent public nonisolated static func run(_ cli: URL, _ arguments: [String],
                                                   _ environment: [String: String]) async throws -> (Int32, Data, Data) {
        let request = ProcessRequest(cli, arguments, environment: environment, errorOutput: .separate,
                                     timeout: timeout, onCancel: .finish)
        let outcome = try await AsyncProcess().run(request)
        return (outcome.succeeded ? 0 : max(outcome.status, 1), outcome.output, outcome.errorOutput)
    }
}
