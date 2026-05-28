import Foundation

enum AgentSessionBridgeContract {
    static let handlerName = "agentSession"
}

struct AgentSessionBridgeRequest {
    let id: String
    let method: String
    let params: [String: Any]

    init(body: Any) throws {
        guard let dictionary = body as? [String: Any],
              let id = dictionary["id"] as? String,
              let method = dictionary["method"] as? String else {
            throw AgentSessionBridgeError.invalidRequest
        }
        self.id = id
        self.method = method
        self.params = dictionary["params"] as? [String: Any] ?? [:]
    }

    func string(_ key: String) -> String? {
        let trimmed = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw AgentSessionBridgeError.missingParameter(key)
        }
        return value
    }

    func rawString(_ key: String) -> String? {
        params[key] as? String
    }

    func requiredRawString(_ key: String) throws -> String {
        guard let value = rawString(key) else {
            throw AgentSessionBridgeError.missingParameter(key)
        }
        return value
    }

    func providerID() throws -> AgentSessionProviderID {
        let rawValue = try requiredString("providerId")
        guard let provider = AgentSessionProviderID(rawValue: rawValue) else {
            throw AgentSessionBridgeError.invalidProvider(rawValue)
        }
        return provider
    }
}

enum AgentSessionBridgeError: LocalizedError {
    case invalidRequest
    case invalidProvider(String)
    case missingParameter(String)
    case unsupportedMethod(String)
    case sessionNotFound(String)
    case sessionAlreadyRunning
    case providerNotReady(String)
    case unsupportedTransport(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return String(localized: "agentSession.bridge.error.invalidRequest", defaultValue: "Invalid bridge request.")
        case .invalidProvider(let provider):
            _ = provider
            return String(
                localized: "agentSession.bridge.error.invalidProvider",
                defaultValue: "The selected provider is unavailable."
            )
        case .missingParameter(let parameter):
            _ = parameter
            return String(
                localized: "agentSession.bridge.error.missingParameter",
                defaultValue: "The request is incomplete."
            )
        case .unsupportedMethod(let method):
            _ = method
            return String(
                localized: "agentSession.bridge.error.unsupportedMethod",
                defaultValue: "This action is not supported."
            )
        case .sessionNotFound(let sessionId):
            _ = sessionId
            return String(
                localized: "agentSession.bridge.error.sessionNotFound",
                defaultValue: "The agent session is no longer available."
            )
        case .sessionAlreadyRunning:
            return String(
                localized: "agentSession.bridge.error.sessionAlreadyRunning",
                defaultValue: "An agent session is already running."
            )
        case .providerNotReady(let provider):
            _ = provider
            return String(
                localized: "agentSession.bridge.error.providerNotReady",
                defaultValue: "The provider is not ready yet."
            )
        case .unsupportedTransport(let transport):
            _ = transport
            return String(
                localized: "agentSession.bridge.error.unsupportedTransport",
                defaultValue: "Agent transport is not supported."
            )
        }
    }
}

func agentSessionIsLoopbackURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

enum AgentSessionHTTPBridge {
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
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
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
