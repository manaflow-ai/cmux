import CryptoKit
public import Foundation

/// Device-signed requests (PROTOCOL.md, Identity): `X-Device-Id`,
/// `X-Device-Ts` and `X-Device-Sig`, the signature over
/// `"<METHOD>\n<path+query>\n<ts>\n<hex sha256 of body or empty>"`.
public struct DeviceRequestSigner: Sendable {
    public static let idHeader = "X-Device-Id"
    public static let timestampHeader = "X-Device-Ts"
    public static let signatureHeader = "X-Device-Sig"

    public let identity: DeviceIdentity
    let now: @Sendable () -> Date

    public init(identity: DeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.now = now
    }

    /// The string a device signs. The body line is the lowercase hex SHA-256
    /// of the body bytes, or empty when there is no body (or it is empty).
    public static func canonical(method: String, pathAndQuery: String, timestamp: Int, body: Data?) -> String {
        let bodyHash = body.flatMap { $0.isEmpty ? nil : SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        return "\(method.uppercased())\n\(pathAndQuery)\n\(timestamp)\n\(bodyHash)"
    }

    /// The URL's percent-encoded path (`/` when empty) and `?query` when it has one.
    public static func pathAndQuery(of url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var path = components?.percentEncodedPath ?? url.path
        if path.isEmpty { path = "/" }
        guard let query = components?.percentEncodedQuery else { return path }
        return path + "?" + query
    }

    /// The three device headers for one request, signed now.
    public func headers(method: String, pathAndQuery: String, body: Data?) throws -> [String: String] {
        let timestamp = Int(now().timeIntervalSince1970)
        let signature = try identity.sign(canonical: Self.canonical(method: method, pathAndQuery: pathAndQuery,
                                                                     timestamp: timestamp, body: body))
        return [Self.idHeader: identity.id, Self.timestampHeader: String(timestamp), Self.signatureHeader: signature]
    }

    /// Sets the device headers on `request` for its method, URL and body.
    public func sign(_ request: inout URLRequest) throws {
        guard let url = request.url else { return }
        let headers = try headers(method: request.httpMethod ?? "GET", pathAndQuery: Self.pathAndQuery(of: url),
                                  body: request.httpBody)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }
}
