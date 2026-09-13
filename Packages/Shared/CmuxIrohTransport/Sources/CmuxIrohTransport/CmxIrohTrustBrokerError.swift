import Foundation

/// Structured error returned by the Iroh trust broker.
struct CmxIrohTrustBrokerError: Decodable {
    let error: String
    /// Which enforcement layer produced a 429.
    let source: CmxIrohTrustBrokerErrorSource?
    /// Broker-generated correlation identifier for operational failures.
    let requestID: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case source
        case requestID = "requestId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
        // Keep the coarse error code when an untrusted or newer server sends
        // an unknown or malformed source.
        source = (try? container.decode(String.self, forKey: .source))
            .flatMap(CmxIrohTrustBrokerErrorSource.init(rawValue:))
        requestID = try? container.decode(String.self, forKey: .requestID)
    }
}
