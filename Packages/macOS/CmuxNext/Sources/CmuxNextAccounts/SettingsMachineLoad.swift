public import CmuxNextAgentPane
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Machines' load rows: relays the page's `cmux.settings.machines.load` to this Mac's
/// acpmux `_acpmux/peers` and answers each peer's name and its load row (`peers[].load`, cmux-tui
/// acpmux placement.rs `load_row`) unchanged, nothing else of the row (never its URL), or no peers
/// when acpmux does not answer. The page (webviews/src/pages/settings/components/HostSections.tsx)
/// reads it while Machines shows, and words it as the composer's machine picker does
/// (webviews ui/machineLoad.ts): one source, so both show the same numbers. acpmux answers from what its
/// links hold (no peer is asked), so a read costs the same with 3 machines or 300.
@MainActor
public final class SettingsMachineLoad: PageProvider {
    public nonisolated static let prefix = "cmux.settings.machines.load"

    /// This app's acpmux; nil in a showcase or with the mock agent host.
    private let environment: @MainActor () -> AcpmuxEnvironment?

    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?) {
        self.environment = environment
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix else { throw PageError.unknownOp(op) }
        guard let socket = environment()?.socketPath,
              let text = try? await AcpmuxPeerList(socketPath: socket).loadRows(),
              let rows = try? JSONValue.parse(Data(text.utf8))
        else { return .object(["peers": .array([])]) }
        return rows
    }
}

public extension PageRoute {
    /// Settings' relays to this app's acpmux (`environment`): Server > This Mac on Your Tailnet, signed in
    /// and out on the app's person connection (``SettingsTailnet``), and Machines' load rows
    /// (``SettingsMachineLoad``).
    static func settingsAcpmux(_ environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> [PageRoute] {
        [PageRoute(prefix: SettingsTailnet.prefix, provider: SettingsTailnet(environment: environment)),
         PageRoute(prefix: SettingsMachineLoad.prefix, provider: SettingsMachineLoad(environment: environment))]
    }
}
