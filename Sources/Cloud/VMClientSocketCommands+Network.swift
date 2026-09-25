import Foundation

extension TerminalController {
    /// `vm.network_get {id}` and `vm.network_update {id, edits}` behind
    /// `cmux vm network`. Updates go through ``VMClient/updateNetworkPolicy(id:edits:)``,
    /// the same edit rules the Network sheet applies.
    nonisolated func socketWorkerCloudNetworkResponse(method: String, id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
            let format = String(
                localized: "socket.cloudVM.network.idRequired",
                defaultValue: "%@ requires `id`. Run `cmux vm ls` to find one."
            )
            return v2Error(id: id, code: "invalid_params", message: String(format: format, method))
        }
        if method == "vm.network_get" {
            return v2CloudCall(id: id, method: method, params: params) {
                try await VMClient.shared.networkPolicy(id: vmId).foundationObject
            }
        }
        let rawEdits = params["edits"] as? [Any] ?? []
        var edits: [CloudNetworkPolicyEdit] = []
        for raw in rawEdits {
            guard let edit = Self.socketWorkerNetworkEdit(raw) else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.cloudVM.network.invalidEdit",
                        defaultValue: "vm.network_update received an edit it does not understand. Use `cmux vm network --help`."
                    )
                )
            }
            edits.append(edit)
        }
        guard !edits.isEmpty else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.cloudVM.network.editsRequired",
                    defaultValue: "vm.network_update requires at least one edit."
                )
            )
        }
        return v2CloudCall(id: id, method: method, params: params, timeoutSeconds: 90) {
            try await VMClient.shared.updateNetworkPolicy(id: vmId, edits: edits).foundationObject
        }
    }

    /// Decodes one `{op, …}` edit object. The op names are the socket contract.
    nonisolated static func socketWorkerNetworkEdit(_ raw: Any) -> CloudNetworkPolicyEdit? {
        guard let object = raw as? [String: Any], let op = socketWorkerString(object["op"]) else { return nil }
        switch op {
        case "set_mode":
            return socketWorkerString(object["mode"]).flatMap(CloudNetworkPolicyMode.init(rawValue:)).map { .setMode($0) }
        case "add_domain":
            return socketWorkerString(object["domain"]).map { .addDomain($0) }
        case "remove_domain":
            return socketWorkerString(object["domain"]).map { .removeDomain($0) }
        case "add_range", "remove_range":
            guard let range = socketWorkerNetworkRange(object) else { return nil }
            return op == "add_range" ? .addRange(range) : .removeRange(range)
        case "add_preset", "remove_preset":
            return socketWorkerString(object["preset"]).map { .setPreset($0, enabled: op == "add_preset") }
        case "set_dns":
            if let bool = object["allow_dns"] as? Bool { return .setAllowDns(bool) }
            return (object["allow_dns"] as? NSNumber).map { .setAllowDns($0.boolValue) }
        case "replace":
            guard let policy = object["policy"], let decoded = try? CloudNetworkPolicy(foundationObject: policy) else { return nil }
            return .replace(decoded)
        default:
            return nil
        }
    }

    private nonisolated static func socketWorkerNetworkRange(_ object: [String: Any]) -> CloudNetworkRange? {
        guard let cidr = socketWorkerString(object["cidr"]) else { return nil }
        var port: Int?
        if let rawPort = object["port"], !(rawPort is NSNull) {
            guard let parsed = socketWorkerInt(rawPort) else { return nil }
            port = parsed
        }
        var transport: CloudNetworkRangeProtocol?
        if let rawProtocol = socketWorkerString(object["protocol"]) {
            guard let parsed = CloudNetworkRangeProtocol(rawValue: rawProtocol.lowercased()) else { return nil }
            transport = parsed
        }
        return CloudNetworkRange(cidr: cidr, port: port, transport: transport, note: socketWorkerString(object["note"]))
    }
}
