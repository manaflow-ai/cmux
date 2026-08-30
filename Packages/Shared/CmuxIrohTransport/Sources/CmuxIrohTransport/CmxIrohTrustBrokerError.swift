import Foundation

/// Structured error returned by the Iroh trust broker.
struct CmxIrohTrustBrokerError: Decodable {
    let error: String
    /// Which enforcement layer produced a 429.
    let source: CmxIrohTrustBrokerErrorSource?

    private enum CodingKeys: String, CodingKey {
        case error
        case source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
        // Keep the coarse error code when an untrusted or newer server sends
        // an unknown or malformed source.
        source = (try? container.decode(String.self, forKey: .source))
            .flatMap(CmxIrohTrustBrokerErrorSource.init(rawValue:))
    }
}
