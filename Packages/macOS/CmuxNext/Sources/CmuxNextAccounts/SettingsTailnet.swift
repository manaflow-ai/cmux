public import CmuxNextAgentPane
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextWakeups
public import Foundation

/// Settings > Server > This Mac on Your Tailnet: relays the page's `cmux.settings.tailnet.state`, `.start`,
/// `.login` and `.logout` to acpmux's `_acpmux/tailnet/<verb>` (cmux-tui acpmux tailnet/embedded.rs) and
/// answers its snapshot unchanged, or null when acpmux has no tailnet or did not take the person's proof.
///
/// acpmux takes these only from the proven person, and the proof's key lives in this app alone (acpmux
/// hub/person.rs), so the relay is here; the page (webviews/src/pages/settings/tailnet.ts) owns the state and
/// every text. Sign-in and sign-out run on the person's click in Settings only; reading the state does not.
@MainActor
public final class SettingsTailnet: PageProvider {
    public nonisolated static let prefix = "cmux.settings.tailnet."
    private static let verbs: Set<String> = ["state", "start", "login", "logout", "joinVM", "leaveVM"]

    /// This app's acpmux; nil in a showcase or with the mock agent host.
    private let environment: @MainActor () -> AcpmuxEnvironment?
    /// The bundled `cmux` CLI. Join keys are supplied as stdin to this process and are never put in argv.
    private let cli: @MainActor () async -> URL?

    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?, cli: @escaping @MainActor () async -> URL?) {
        self.environment = environment
        self.cli = cli
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let verb = String(op.dropFirst(Self.prefix.count))
        guard op.hasPrefix(Self.prefix), Self.verbs.contains(verb) else { throw PageError.unknownOp(op) }
        guard verb == "state" || (context.page == PageDescriptor.settings.id && context.userGesture) else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        if verb == "joinVM" || verb == "leaveVM" {
            return try await runVM(verb: verb, params: params)
        }
        guard let environment = environment(), let line = await AcpmuxPersonLine.open(environment) else { return .null }
        defer { line.close() }
        guard line.isPerson, let reply = await line.call("_acpmux/tailnet/\(verb)", [:]) else { return .null }
        return (try? JSONValue.parse(JSONSerialization.data(withJSONObject: reply))) ?? .null
    }

    private func runVM(verb: String, params: JSONValue) async throws -> JSONValue {
        guard let vm = params["vm"]?.stringValue, !vm.isEmpty else {
            return ["ok": .bool(false), "errorCode": .string("missing_vm")]
        }
        guard let binary = await cli() else {
            return ["ok": .bool(false), "errorCode": .string("cli_unavailable")]
        }
        // Ask the bundled CLI for its machine-readable envelope. The global flag is safe for both
        // join and leave, and keeps the page from parsing human-facing progress text.
        var arguments = ["--json", "vm", "tailnet", verb == "joinVM" ? "join" : "leave", vm]
        var stdin: Data?
        if verb == "joinVM" {
            guard let key = params["key"]?.stringValue, !key.isEmpty else {
                return ["ok": .bool(false), "errorCode": .string("missing_key")]
            }
            stdin = Data(key.utf8)
            arguments += ["--key-stdin"]
            if params["oauth"]?.boolValue == true { arguments.append("--oauth") }
            if let value = params["loginServer"]?.stringValue, !value.isEmpty { arguments += ["--login-server", value] }
            if let value = params["loginServer"]?.stringValue, !value.isEmpty, params["allowHttp"]?.boolValue == true {
                arguments.append("--allow-http")
            }
            // The setting is a template: {vm} names the Cloud machine being joined.
            if let value = params["hostname"]?.stringValue, !value.isEmpty {
                arguments += ["--hostname", value.replacingOccurrences(of: "{vm}", with: vm)]
            }
            for tag in params["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !tag.isEmpty { arguments += ["--tag", tag] }
            if params["ssh"]?.boolValue == true { arguments.append("--ssh") }
            if params["ephemeral"]?.boolValue == true { arguments.append("--ephemeral") }
            for port in params["servePorts"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !port.isEmpty { arguments += ["--serve", port] }
            if params["switch"]?.boolValue == true { arguments.append("--switch") }
        }
        let request = ProcessRequest(binary, arguments, input: stdin, errorOutput: .separate, timeout: .seconds(240))
        let result = try await AsyncProcess().run(request)
        let lines = String(decoding: result.output, as: UTF8.self).split(separator: "\n")
        if let line = lines.last(where: { (line: Substring) -> Bool in !line.allSatisfy { (character: Character) -> Bool in character.isWhitespace } }), let answer = try? JSONValue.parse(Data(line.utf8)) {
            return answer
        }
        let detail = String(decoding: result.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["ok": .bool(false), "error": .string(detail.isEmpty ? "The tailnet command failed (exit \(result.status))." : detail)]
    }
}
