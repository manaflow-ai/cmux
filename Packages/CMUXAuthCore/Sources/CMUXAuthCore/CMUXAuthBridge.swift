import Foundation

public enum CMUXAuthBridgeDefaults {
    public static let cachedUserKey = "cmux.auth.cachedUser"
    public static let selectedTeamIDKey = "cmux.auth.selectedTeamID"
    public static let sessionTokensKey = "cmux.auth.hasTokens"
}

public enum CMUXAuthBridgeJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: CMUXAuthBridgeJSONValue])
    case array([CMUXAuthBridgeJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CMUXAuthBridgeJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([CMUXAuthBridgeJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

public struct CMUXAuthBridgeRequest: Codable, Equatable, Sendable {
    public let method: String
    public let params: [String: CMUXAuthBridgeJSONValue]

    public init(method: String, params: [String: CMUXAuthBridgeJSONValue]) {
        self.method = method
        self.params = params
    }
}

public struct CMUXAuthBridgeUser: Codable, Equatable, Sendable {
    public let id: String
    public let email: String?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
    }

    public init(id: String, email: String?, displayName: String?) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }

    public init(_ user: CMUXAuthUser) {
        self.init(id: user.id, email: user.primaryEmail, displayName: user.displayName)
    }
}

public struct CMUXAuthBridgeResult: Codable, Equatable, Sendable {
    public let signedIn: Bool
    public let authenticated: Bool
    public let required: Bool
    public let isRestoringSession: Bool
    public let isLoading: Bool
    public let timedOut: Bool
    public let user: CMUXAuthBridgeUser?
    public let teams: [[String: String]]
    public let selectedTeamID: String?
    public let platform: String
    public let backend: String
    public let mode: String
    public let detail: String

    enum CodingKeys: String, CodingKey {
        case signedIn = "signed_in"
        case authenticated
        case required
        case isRestoringSession = "is_restoring_session"
        case isLoading = "is_loading"
        case timedOut = "timed_out"
        case user
        case teams
        case selectedTeamID = "selected_team_id"
        case platform
        case backend
        case mode
        case detail
    }
}

public enum CMUXAuthBridgeError: Error, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case backendUnavailable

    public var description: String {
        switch self {
        case .invalidRequest(let reason):
            return "invalid_request:\(reason)"
        case .backendUnavailable:
            return "backend_unavailable"
        }
    }
}

public final class CMUXAuthBridge {
    private let identityStore: CMUXAuthIdentityStore
    private let sessionCache: CMUXAuthSessionCache
    private let keyValueStore: CMUXAuthKeyValueStore

    public init(keyValueStore: CMUXAuthKeyValueStore = UserDefaults.standard) {
        self.keyValueStore = keyValueStore
        self.identityStore = CMUXAuthIdentityStore(
            keyValueStore: keyValueStore,
            key: CMUXAuthBridgeDefaults.cachedUserKey
        )
        self.sessionCache = CMUXAuthSessionCache(
            keyValueStore: keyValueStore,
            key: CMUXAuthBridgeDefaults.sessionTokensKey
        )
    }

    public func handle(_ request: CMUXAuthBridgeRequest) throws -> CMUXAuthBridgeResult {
        switch request.method {
        case "auth.status":
            return try status(detail: "auth_bridge_available")
        case "auth.login", "auth.begin_sign_in":
            if try identityStore.load() != nil || sessionCache.hasTokens {
                return try status(detail: "auth_bridge_available")
            }
            if let user = userFromParams(request.params) {
                try identityStore.save(user)
                sessionCache.setHasTokens(true)
                return try status(detail: "auth_bridge_cached_login")
            }
            throw CMUXAuthBridgeError.backendUnavailable
        case "auth.sign_out":
            identityStore.clear()
            sessionCache.clear()
            keyValueStore.removeObject(forKey: CMUXAuthBridgeDefaults.selectedTeamIDKey)
            return try status(detail: "auth_bridge_signed_out")
        default:
            throw CMUXAuthBridgeError.invalidRequest("unsupported_method")
        }
    }

    public func handleJSONRequest(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(CMUXAuthBridgeRequest.self, from: data)
        let result = try handle(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    private func status(detail: String) throws -> CMUXAuthBridgeResult {
        let cachedUser = try identityStore.load()
        let signedIn = cachedUser != nil || sessionCache.hasTokens
        return CMUXAuthBridgeResult(
            signedIn: signedIn,
            authenticated: signedIn,
            required: false,
            isRestoringSession: false,
            isLoading: false,
            timedOut: false,
            user: cachedUser.map(CMUXAuthBridgeUser.init),
            teams: [],
            selectedTeamID: normalized(keyValueStore.string(forKey: CMUXAuthBridgeDefaults.selectedTeamIDKey)),
            platform: "linux",
            backend: "cmux_auth_core_bridge",
            mode: "bridge",
            detail: detail
        )
    }

    private func userFromParams(_ params: [String: CMUXAuthBridgeJSONValue]) -> CMUXAuthUser? {
        guard let email = normalized(params["email"]?.stringValue) else {
            return nil
        }
        return CMUXAuthUser(
            id: normalized(params["user_id"]?.stringValue) ?? email,
            primaryEmail: email,
            displayName: normalized(params["display_name"]?.stringValue)
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
