import Foundation

/// Identifies one running cmux app process without consulting a socket or the
/// process table. Every terminal spawned by that process inherits this value.
struct AgentCmuxRuntimeIdentity: Codable, Sendable, Equatable {
    var id: String
    var socketPath: String?
    var bundleIdentifier: String?

    init?(environment: [String: String]) {
        guard let id = Self.normalized(environment["CMUX_RUNTIME_ID"]) else { return nil }
        self.id = id
        socketPath = Self.normalized(environment["CMUX_SOCKET_PATH"])
            ?? Self.normalized(environment["CMUX_SOCKET"])
        bundleIdentifier = Self.normalized(environment["CMUX_BUNDLE_ID"])
    }

    init(id: String, socketPath: String?, bundleIdentifier: String?) {
        self.id = id
        self.socketPath = socketPath
        self.bundleIdentifier = bundleIdentifier
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Chooses current-runtime output without socket I/O. `--all` remains the
/// explicit history view, while shells from older cmux versions retain the
/// legacy evidence filter because they do not carry `CMUX_RUNTIME_ID`.
enum AgentSessionQueryScope: Sendable, Equatable {
    case history
    case currentRuntime(String)
    case legacyUnscoped

    init(includeHistory: Bool, environment: [String: String]) {
        if includeHistory {
            self = .history
        } else if let runtime = AgentCmuxRuntimeIdentity(environment: environment) {
            self = .currentRuntime(runtime.id)
        } else {
            self = .legacyUnscoped
        }
    }

    func includes(
        recordRuntime: AgentCmuxRuntimeIdentity?,
        runRuntime: AgentCmuxRuntimeIdentity?,
        legacyVisible: Bool
    ) -> Bool {
        switch self {
        case .history:
            return true
        case let .currentRuntime(runtimeId):
            return (runRuntime ?? recordRuntime)?.id == runtimeId
        case .legacyUnscoped:
            return legacyVisible
        }
    }
}
