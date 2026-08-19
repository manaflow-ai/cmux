public import Foundation
import CMUXMobileCore

/// Injectable URL-loading boundary used by the trust broker client.
///
/// Tests stub this seam; production uses ``PeerBrokerURLSessionTransport``.
public protocol PeerBrokerHTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production URLSession transport.
///
/// Delegates to the shared credentialed session, which is cookie-free,
/// cache-free, response-size-bounded, and rejects redirects before Foundation
/// can forward credential headers cross-origin.
public struct PeerBrokerURLSessionTransport: PeerBrokerHTTPTransporting {
    private let session: CmxCredentialedHTTPSession

    public init(configuration: sending URLSessionConfiguration = .ephemeral) {
        session = CmxCredentialedHTTPSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
