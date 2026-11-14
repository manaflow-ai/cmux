import Foundation

/// Decodes the authenticated Cloud VM attach-endpoint response.
public struct CmxCloudAttach: Sendable {
    /// Request this transport from `POST /api/vm/{id}/attach-endpoint`.
    public static let remoteTransport = "cmux-remote"

    /// Creates a stateless endpoint codec.
    public init() {}

    /// Decodes the current Cloud daemon contract without granting connection trust.
    ///
    /// Only consume responses obtained from the authenticated API for the caller's
    /// machine. Decoding arbitrary JSON or a scanned URL does not establish trust.
    /// - Parameter data: The raw API response body.
    /// - Returns: The daemon endpoint, including its explicit carrier trust flag.
    /// - Throws: `CmxCloudAttachError` for another transport, or `DecodingError`
    ///   for missing or malformed fields.
    public func decode(_ data: Data) throws -> CmxCloudAttachEndpoint {
        try JSONDecoder().decode(CmxCloudAttachEndpoint.self, from: data)
    }
}
