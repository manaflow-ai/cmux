public import CmuxNextAgentPane
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

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
    private static let verbs: Set<String> = ["state", "start", "login", "logout"]

    /// This app's acpmux; nil in a showcase or with the mock agent host.
    private let environment: @MainActor () -> AcpmuxEnvironment?

    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?) {
        self.environment = environment
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let verb = String(op.dropFirst(Self.prefix.count))
        guard op.hasPrefix(Self.prefix), Self.verbs.contains(verb) else { throw PageError.unknownOp(op) }
        guard verb == "state" || (context.page == PageDescriptor.settings.id && context.userGesture) else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        guard let environment = environment(), let line = await AcpmuxPersonLine.open(environment) else { return .null }
        defer { line.close() }
        guard line.isPerson, let reply = await line.call("_acpmux/tailnet/\(verb)", [:]) else { return .null }
        return (try? JSONValue.parse(JSONSerialization.data(withJSONObject: reply))) ?? .null
    }
}
