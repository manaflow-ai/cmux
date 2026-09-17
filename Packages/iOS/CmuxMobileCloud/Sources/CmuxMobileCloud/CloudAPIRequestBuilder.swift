public import Foundation

/// Builds the exact `URLRequest`s the phone sends to `/api/vm`.
///
/// Pure, so request shape is tested without a network. Field names mirror the
/// Mac's `VMClient` so the control plane sees one client contract.
public struct CloudAPIRequestBuilder: Sendable, Equatable {
    /// The cmux web API origin without a trailing slash.
    public var baseURL: String
    /// Per-request deadline in seconds.
    public var timeout: TimeInterval

    /// Creates a builder.
    /// - Parameters:
    ///   - baseURL: The web API origin, with or without a trailing slash.
    ///   - timeout: Per-request deadline; attach calls use `attachTimeout`.
    public init(baseURL: String, timeout: TimeInterval = 20) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.timeout = timeout
    }

    /// Attach can wait on the daemon coming up, so it gets a longer deadline.
    public static let attachTimeout: TimeInterval = 90

    /// `GET /api/vm`.
    public func listMachines(accessToken: String, refreshToken: String) throws -> URLRequest {
        try request("GET", path: "/api/vm", body: nil, accessToken: accessToken, refreshToken: refreshToken)
    }

    /// `POST /api/vm/tunnel` with this device's public key and fingerprint.
    public func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        deviceName: String?,
        accessToken: String,
        refreshToken: String
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "clientPublicKey": clientPublicKey,
            "deviceFingerprint": deviceFingerprint,
        ]
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["deviceName"] = deviceName
        }
        return try request("POST", path: "/api/vm/tunnel", body: body, accessToken: accessToken, refreshToken: refreshToken)
    }

    /// `POST /api/vm/<id>/attach-endpoint` for the `cmux-remote` transport.
    public func openAttach(
        machineID: String,
        deviceFingerprint: String,
        clientCapabilities: [String],
        accessToken: String,
        refreshToken: String
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "transport": "cmux-remote",
            "deviceFingerprint": deviceFingerprint,
        ]
        let capabilities = Self.sanitizedClientCapabilities(clientCapabilities)
        if !capabilities.isEmpty { body["clientCapabilities"] = capabilities }
        var request = try request(
            "POST",
            path: "/api/vm/\(try Self.pathSegment(machineID))/attach-endpoint",
            body: body,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
        request.timeoutInterval = Self.attachTimeout
        return request
    }

    /// `POST /api/vm/<id>/cmux-remote/approve` for a first-contact invitation.
    public func approveEnrollment(
        machineID: String,
        invitationId: String,
        accessToken: String,
        refreshToken: String
    ) throws -> URLRequest {
        try request(
            "POST",
            path: "/api/vm/\(try Self.pathSegment(machineID))/cmux-remote/approve",
            body: ["invitationId": invitationId],
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    /// Well-formed capability tokens only: short lowercase slugs, deduplicated,
    /// capped like the server's validator.
    public static func sanitizedClientCapabilities(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for entry in raw {
            let token = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  seen.insert(token).inserted else { continue }
            tokens.append(token)
            if tokens.count == 16 { break }
        }
        return tokens
    }

    private static func pathSegment(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.contains("/") else {
            throw CloudAPIError.invalidURL("machine id \(value)")
        }
        return encoded
    }

    private func request(
        _ method: String,
        path: String,
        body: [String: Any]?,
        accessToken: String,
        refreshToken: String
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw CloudAPIError.invalidURL(baseURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }
}
