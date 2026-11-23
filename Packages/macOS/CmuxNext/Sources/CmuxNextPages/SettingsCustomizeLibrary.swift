public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups

/// Settings > Appearance > Customization Library (webviews `CustomizeLibraryCard.tsx`):
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
    nonisolated static let changes: Set<String> = ["on", "off", "order", "remove", "reset"]
    nonisolated static let timeout: Duration = .seconds(60)

    /// One CLI run: arguments in, exit status, stdout and stderr out.
    public typealias Runner = @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: Runner

    /// `settingsFile` points the CLI at the settings file the app reads (`CMUX_NEXT_CONFIG_FILE`) when
    /// it is not the CLI's default; nil or the default keeps the CLI's own (see `environment`).
    public init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?, runCLI: @escaping Runner) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
    }

    /// The app's: the bundled CLI run as a child process.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?) {
        self.init(cli: cli, settingsFile: settingsFile, runCLI: { try await SettingsCustomizeLibrary.run($0, $1, $2) })
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
        let environment = Self.environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile())
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
        case "reset":
            // Every entry off (`cmux customize library reset`), the palette's Reset Customization Library.
            return base + ["reset"]
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
            throw PageError.invalidParams("verb is list, on, off, order, remove or reset")
        }
    }

    /// Reset Customization Library (`customize.library.reset`, person-only): `cmux --json customize library
    /// reset` with the card's environment, so it resets the library the card lists. The CLI's answer, or
    /// its refusal (`code`, `message`) as the thrown error's text.
    public static func reset(cli: URL, settingsFile: URL?, runCLI: Runner = { try await SettingsCustomizeLibrary.run($0, $1, $2) }) async throws -> JSONValue {
        let environment = environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile)
        let (status, stdout, stderr) = try await runCLI(cli, try arguments(.object(["verb": .string("reset")])), environment)
        guard status == 0 else {
            let refusal = try? JSONValue.parse(stderr)
            throw PageError(code: refusal?["code"]?.stringValue ?? "cmux.customize.failed",
                            message: refusal?["message"]?.stringValue ?? String(decoding: stderr, as: UTF8.self))
        }
        return (try? JSONValue.parse(stdout)) ?? .object([:])
    }

    /// The CLI's environment: the app's own, naming the app's settings file only when it is not the
    /// CLI's default (`~/.config/cmux/cmux-next.json`). An override also moves the CLI's library
    /// state into the config folder (cmux-customize `Roots::from`), so naming the default file would
    /// hide every entry an ordinary `cmux customize` run kept.
    nonisolated static func environment(_ base: [String: String], settingsFile: URL?) -> [String: String] {
        var environment = base
        guard let file = settingsFile else { return environment }
        if let home = environment["HOME"], !home.isEmpty,
           file.standardizedFileURL.path == URL(fileURLWithPath: home).appendingPathComponent(".config/cmux/cmux-next.json").standardizedFileURL.path {
            return environment
        }
        environment["CMUX_NEXT_CONFIG_FILE"] = file.path
        return environment
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
