import Foundation

enum AgentSessionHTTPBridge {
    private static let maxResponseBodyBytes = 1024 * 1024

    static func perform(request: AgentSessionBridgeRequest) async throws -> [String: Any] {
        guard let url = URL(string: try request.requiredString("url")),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AgentSessionBridgeError.missingParameter("url")
        }
        guard agentSessionIsLoopbackURL(url) else {
            throw AgentSessionBridgeError.invalidRequest
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
        urlRequest.httpMethod = request.string("method") ?? "GET"
        if let headers = request.params["headers"] as? [String: String] {
            for (key, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = request.params["body"] as? String {
            urlRequest.httpBody = body.data(using: .utf8)
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        let expectedLength = httpResponse?.expectedContentLength ?? -1
        if expectedLength > Self.maxResponseBodyBytes {
            throw AgentSessionBridgeError.invalidRequest
        }
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            if data.count >= Self.maxResponseBodyBytes {
                throw AgentSessionBridgeError.invalidRequest
            }
            data.append(byte)
        }
        let headerFields = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = "\(entry.value)"
        } ?? [:]
        return [
            "status": httpResponse?.statusCode ?? 0,
            "headers": headerFields,
            "bodyText": String(data: data, encoding: .utf8) ?? ""
        ]
    }
}
