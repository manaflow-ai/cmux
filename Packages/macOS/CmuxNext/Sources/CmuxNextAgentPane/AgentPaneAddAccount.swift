import Foundation

/// A bounded Add account form, forwarded unchanged to the daemon's existing local route writer.
/// Rust owns route kinds, credential-reference validation and defaults; replacement is never offered.
public nonisolated struct AgentPaneAddAccount: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let fields: [String: String]

    init?(params: [String: Any]?) {
        let allowed: Set<String> = ["id", "kind", "name", "accountHome", "anthropicBaseUrl", "openaiBaseUrl", "secret"]
        guard let params, Set(params.keys).isSubset(of: allowed),
              let fields = params as? [String: String],
              let id = fields["id"], !id.isEmpty, id.utf8.count <= 128,
              let kind = fields["kind"], !kind.isEmpty, kind.utf8.count <= 128,
              fields.values.allSatisfy({ $0.utf8.count <= 4096 }) else { return nil }
        self.id = id
        self.kind = kind
        self.fields = fields
    }

    @MainActor
    func reply(in model: AgentPaneModel) async -> [String: Any] {
        guard !model.remoteChat else { return AgentPaneModel.unsupported("account.add") }
        // The App records native input; no parameter supplied by the page can grant this.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard let socket = model.transport.acpmuxSocket else { return AgentPaneModel.transportFailure(.noConnection) }
        do {
            let value = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/route/add",
                                                          params: fields, deadline: .seconds(20), detailed: true)
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
