// Only the launcher: CmuxNextDaemon has a JSONValue of its own, and this file speaks the page's.
import class CmuxNextDaemon.BundledExecutable
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextWakeups
public import Foundation

/// The agent chat's Customize bar (webviews `agent-session/acpmux/customizeBar/`): `cmux.customize.run
/// {verb, arg?}` runs `cmux --json customize VERB [ARG]` through the bundled CLI and answers its JSON,
/// or the error's envelope on a refusal, as Settings' try-on bar does (``CustomizeTryOnPage``). The
/// engine is the CLI's (cmux-customize), so the bar, the CLI and the `customize_*` MCP tools never
/// differ, and the chat's agent and the person's clicks change the same draft.
///
/// The page reaches it on this Mac only: the chat page is the app's own, and nothing here forwards to
/// another machine, so a chat running elsewhere still changes this Mac's cmux, the one on screen.
@MainActor
public final class CustomizeChatPage: PageProvider {
    /// The ops' namespace on the agent page (``PageDescriptor/agent``).
    public static let namespace = "cmux.customize."
    /// The one op.
    public static let op = "cmux.customize.run"
    /// What the bar may run, and what each takes after the verb.
    public enum Argument: Sendable { case none, optionalGeneration, name, optionalNote }
    public nonisolated static let verbs: [String: Argument] = [
        "status": .none, "diff": .none, "profiles": .none, "generations": .none,
        "apply": .optionalNote, "discard": .none, "rollback": .optionalGeneration,
        "save": .name, "use": .name, "keep": .none, "revert": .none,
    ]

    /// The provider every agent page routes `cmux.customize.*` to: the app bundle's `cmux` (or
    /// `CMUX_NEXT_TUI_BIN`), found once and kept, as ``BundledExecutable`` does for the app.
    public static let shared: CustomizeChatPage = {
        let bundled = BundledExecutable.cli(resources: Bundle.main.resourceURL, work: BackgroundWork())
        return CustomizeChatPage(cli: { await bundled.resolve() })
    }()

    private let cli: @MainActor () async -> URL?
    private let runCLI: @Sendable (URL, [String]) async throws -> (Int32, Data, Data)

    /// - Parameter cli: The CLI to run; nil (a build with no bundled CLI) answers `cmux.page.unavailable`.
    public init(cli: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String]) async throws -> (Int32, Data, Data) = CustomizeTryOnPage.run) {
        self.cli = cli
        self.runCLI = runCLI
    }

    /// The CLI's words for `params`, or nil when the verb or its argument is not one the bar may run.
    public nonisolated static func arguments(_ params: JSONValue) -> [String]? {
        guard let verb = params["verb"]?.stringValue, let takes = verbs[verb] else { return nil }
        let arg = params["arg"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = ["--json", "customize", verb]
        switch takes {
        case .none:
            return arg.isEmpty ? words : nil
        case .optionalGeneration:
            if arg.isEmpty { return words }
            return arg.count <= 9 && arg.allSatisfy(\.isASCIIDigitCharacter) ? words + [arg] : nil
        case .name:
            return isProfileName(arg) ? words + [arg] : nil
        case .optionalNote:
            // A label; `--` so a note that starts with a dash is never read as a flag.
            if arg.isEmpty { return words }
            return arg.count <= 200 && !arg.contains("\n") ? words + ["--", arg] : nil
        }
    }

    /// A profile name as the CLI takes it: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
    public nonisolated static func isProfileName(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 64, first.isASCIIDigitCharacter || ("a"..."z").contains(first) else { return false }
        return name.allSatisfy { $0.isASCIIDigitCharacter || ("a"..."z").contains($0) || $0 == "-" || $0 == "_" }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard let arguments = Self.arguments(params) else {
            throw PageError.invalidParams("verb is one of \(Self.verbs.keys.sorted().joined(separator: ", ")), with its argument")
        }
        guard let cli = await cli() else {
            throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI")
        }
        let (status, stdout, stderr) = try await runCLI(cli, arguments)
        return (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
    }
}

private extension Character {
    nonisolated var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}
