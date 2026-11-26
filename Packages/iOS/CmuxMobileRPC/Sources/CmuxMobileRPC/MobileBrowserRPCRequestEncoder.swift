import Foundation

/// Encodes typed browser RPC parameters into the client's JSON request envelope.
struct MobileBrowserRPCRequestEncoder: Sendable {
    /// Creates a stateless browser request encoder.
    init() {}

    /// Encodes one typed browser RPC request.
    func requestData<Parameters: Encodable>(method: String, parameters: Parameters) throws -> Data {
        let encoded = try JSONEncoder().encode(parameters)
        guard let params = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw MobileShellConnectionError.invalidResponse
        }
        return try MobileCoreRPCClient.requestData(method: method, params: params)
    }
}
