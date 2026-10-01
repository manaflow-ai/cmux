import CmuxConversation

/// What this client needs from acpmux, and what a connected daemon offers.
struct AcpmuxRequirements {
    /// Methods this client cannot work without.
    static let requiredMethods = ["_acpmux/attach", "_acpmux/watch", "_acpmux/events", "_acpmux/dequeue", "_acpmux/retry", "_acpmux/permission_respond"]

    /// Reads capabilities from the daemon's schema; `nil` when it lacks a
    /// required method (the host needs an update).
    func capabilities(schema: JSONValue, version: String) -> BackendCapabilities? {
        guard case let .object(methods)? = schema["methods"] else { return nil }
        guard Self.requiredMethods.allSatisfy({ methods[$0] != nil }) else { return nil }
        let transfers = schema["attachmentTransfer"] != nil
        var extensions: Set<String> = ["acpmux.policy", "acpmux.harness"]
        if methods["_acpmux/peers"] != nil { extensions.insert("acpmux.peers") }
        return BackendCapabilities(attachments: transfers, steering: true, dequeue: true, retry: true, fork: true, backwardPaging: true, idempotentSend: true, extensions: extensions, version: version)
    }
}
