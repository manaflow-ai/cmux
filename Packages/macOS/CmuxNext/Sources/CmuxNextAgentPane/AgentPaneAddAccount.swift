import Foundation

/// A bounded Add account form, forwarded unchanged to the daemon's existing local route writer.
/// Rust owns route kinds, credential-reference validation and defaults; replacement is never offered.
public nonisolated struct AgentPaneAddAccount: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let family: String
    public let fields: [String: String]
    /// A Codex login in a shadow home of the CLI's own (`shadow: true` on `_acpmux/route/add`).
    public let shadow: Bool

    init?(params: [String: Any]?) {
        let allowed: Set<String> = ["id", "kind", "family", "name", "accountHome", "secret", "shadow"]
        guard var params, Set(params.keys).isSubset(of: allowed) else { return nil }
        let shadow = params.removeValue(forKey: "shadow")
        guard shadow == nil || shadow is Bool,
              let fields = params as? [String: String],
              let id = fields["id"], !id.isEmpty, id.utf8.count <= 128,
              let kind = fields["kind"], !kind.isEmpty, kind.utf8.count <= 128,
              let family = fields["family"], !family.isEmpty, family.utf8.count <= 128,
              fields.values.allSatisfy({ $0.utf8.count <= 4096 }) else { return nil }
        self.id = id
        self.kind = kind
        self.family = family
        self.shadow = shadow as? Bool ?? false
        self.fields = fields.merging(Self.expandedHome(fields["accountHome"])) { _, home in home }
    }

    /// The page offers a new login a folder of its own as `~/.cmux/accounts/<id>`: it knows no home
    /// path, and the daemon takes only an absolute one. Anything else goes through as written.
    static func expandedHome(_ home: String?, homeDirectory: String = NSHomeDirectory()) -> [String: String] {
        guard let home, home.hasPrefix("~/"), home.count > 2 else { return [:] }
        return ["accountHome": (homeDirectory as NSString).appendingPathComponent(String(home.dropFirst(2)))]
    }

    @MainActor
    func reply(in model: AgentPaneModel) async -> [String: Any] {
        guard !model.remoteChat else { return AgentPaneModel.unsupported("account.add") }
        // The App records native input; no parameter supplied by the page can grant this.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard let socket = model.transport.acpmuxSocket else { return AgentPaneModel.transportFailure(.noConnection) }
        do {
            var params: [String: any Sendable] = ["families": [family]]
            for (key, value) in fields where key != "family" { params[key] = value }
            if shadow { params["shadow"] = true }
            let value = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/route/add",
                                                          params: params, deadline: .seconds(20), detailed: true)
            return AgentPaneReply.success(value)
        } catch let error as AcpmuxRPCError {
            return AgentPaneReply.failure(code: "account.failed", message: error.message)
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            return AgentPaneReply.failure(code: "account.failed", message: message)
        } catch {
            return AgentPaneModel.transportFailure(.noConnection)
        }
    }
}
