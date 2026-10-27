nonisolated enum AgentPaneUploadError: Error, Equatable, Sendable {
    case rpc(String)
    case rpcDetails(code: String, message: String, details: [String: String])

    var failure: (code: String, message: String, details: [String: String]) {
        switch self {
        case .rpc(let message): return ("upload_failed", message, [:])
        case .rpcDetails(let code, let message, let details): return (code, message, details)
        }
    }
}
