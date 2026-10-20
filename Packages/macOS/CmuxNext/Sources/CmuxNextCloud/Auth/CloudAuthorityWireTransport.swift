package import Foundation
import CmuxInstallAuthCore

/// Builds owner-fixed WebSocket requests with header-only credentials and no redirect following.
package struct CloudAuthorityWireTransport: Sendable {
    private let origin: URL
    private let headers: [String: String]
    package init(origin: URL, headers: [String: String]) { self.origin = origin; self.headers = headers }

    package func connect(_ lease: CloudAuthorityWireLease) throws -> any CloudAuthorityWireSocket {
        CloudAuthorityURLSocket(request: try request(lease))
    }

    func request(_ lease: CloudAuthorityWireLease) throws -> URLRequest {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              headers.keys.allSatisfy({ $0.lowercased() == InstallAuthClient.clientVersionHeader }) else {
            throw CloudAuthorityWireLease.Failure.origin
        }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/wire/" + lease.owner.rawValue
        guard let url = parts.url else { throw CloudAuthorityWireLease.Failure.origin }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer " + lease.token, forHTTPHeaderField: "Authorization")
        request.setValue(lease.owner == .team ? "cmux.wire.v1, team." + lease.team : "cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }
}
