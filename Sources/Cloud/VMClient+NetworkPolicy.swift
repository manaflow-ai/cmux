import Foundation

extension VMClient {
    /// The preset catalog and the domains cmux always allows. A successful
    /// answer is also proof that the control plane understands network policy.
    func networkPresets() async throws -> CloudNetworkPresetCatalog {
        try await withOperation(.network, foreground: false) {
            let (data, http) = try await request("GET", path: "/api/vm/network-presets", timeoutSeconds: 30)
            try Self.ensureNetworkPolicyOK(http, data: data)
            return try JSONDecoder().decode(CloudNetworkPresetCatalog.self, from: data)
        }
    }

    /// The stored policy of one machine and whether its provider rules match it.
    func networkPolicy(id: String) async throws -> CloudNetworkPolicyStatus {
        try await withOperation(.network, foreground: false) {
            let encodedID = try pathSegment(id, fieldName: "vm id")
            let (data, http) = try await request("GET", path: "/api/vm/\(encodedID)/network", timeoutSeconds: 30)
            try Self.ensureNetworkPolicyOK(http, data: data)
            return try JSONDecoder().decode(CloudNetworkPolicyStatus.self, from: data)
        }
    }

    /// Replaces the machine's policy. The server applies it live, without a restart.
    func setNetworkPolicy(id: String, policy: CloudNetworkPolicy) async throws -> CloudNetworkPolicyStatus {
        try await withOperation(.network, foreground: true) {
            let encodedID = try pathSegment(id, fieldName: "vm id")
            let (data, http) = try await request(
                "PUT", path: "/api/vm/\(encodedID)/network", jsonBody: policy.foundationObject, timeoutSeconds: 60
            )
            try Self.ensureNetworkPolicyOK(http, data: data)
            return try JSONDecoder().decode(CloudNetworkPolicyStatus.self, from: data)
        }
    }

    /// The shared read-modify-write every entrypoint uses for incremental
    /// changes: read the stored policy, apply the edits with the same rules the
    /// editor uses, and write the result. One operation covers all three steps.
    func updateNetworkPolicy(id: String, edits: [CloudNetworkPolicyEdit]) async throws -> CloudNetworkPolicyStatus {
        try await withOperation(.network, foreground: true) {
            let current = try await networkPolicy(id: id)
            var policy = current.policy
            let known = current.presets.isEmpty ? nil : Set(current.presets.map(\.id))
            for edit in edits {
                try policy.apply(edit, knownPresetIDs: known)
            }
            return try await setNetworkPolicy(id: id, policy: policy)
        }
    }

    /// Typed 400/409 refusals first, so callers can show the server's message
    /// instead of the generic HTTP error text.
    private static func ensureNetworkPolicyOK(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        if let refusal = CloudNetworkPolicyRequestError.from(status: http.statusCode, body: body) { throw refusal }
        throw VMClientError.httpStatus(http.statusCode, body)
    }
}
