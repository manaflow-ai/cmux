import Foundation

extension CloudDaemon {
    /// cmux-cloud-api `vm.agent_key_create` (the VM API's `POST /v1/agent-keys`, owner auth) with the planned body as
    /// JSON text: the VM API's status and body, or status 0 for no answer, which Rust reads as unreachable. `failure`
    /// then names why (no cmux, the daemon's refusal, an answer that is no `{status, body}`; never a credential), so
    /// "the VM service didn't answer" is told apart from a call that never left this Mac. Nil when the VM API answered.
    public func vmAgentKeyMint(bodyJSON: String) async -> (status: Int, body: Data, failure: String?) {
        struct Reply: Decodable { var status: Int; var body: String }
        let data: Data
        do {
            data = try await daemon("vm.agent_key_create", ["body_json": bodyJSON], timeout: .seconds(24))
        } catch {
            return (0, Data(), "cloud.vm.agent_key_create: \(error)")
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return (0, Data(), "cloud.vm.agent_key_create answered no {status, body}")
        }
        return (reply.status, Data(reply.body.utf8), nil)
    }
}
