import Foundation

/// Identifies one running cmux app process without consulting a socket or the
/// process table. Every terminal spawned by that process inherits this value.
struct AgentCmuxRuntimeIdentity: Codable, Sendable, Equatable {
    var id: String
    var socketPath: String?
    var bundleIdentifier: String?
    var processId: Int?
    var processStartSeconds: Int64?
    var processStartMicroseconds: Int64?

    init?(environment: [String: String]) {
        guard let id = Self.normalized(environment["CMUX_RUNTIME_ID"]) else { return nil }
        self.id = id
        socketPath = Self.normalized(environment["CMUX_SOCKET_PATH"])
            ?? Self.normalized(environment["CMUX_SOCKET"])
        bundleIdentifier = Self.normalized(environment["CMUX_BUNDLE_ID"])
        processId = nil
        processStartSeconds = nil
        processStartMicroseconds = nil
    }

    init(
        id: String,
        socketPath: String?,
        bundleIdentifier: String?,
        processId: Int? = nil,
        processStartSeconds: Int64? = nil,
        processStartMicroseconds: Int64? = nil
    ) {
        self.id = id
        self.socketPath = socketPath
        self.bundleIdentifier = bundleIdentifier
        self.processId = processId
        self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds
    }

    /// The connected app owns runtime identity. Hook providers may sanitize
    /// inherited environment variables, and a surviving process can retain a
    /// stale value across an app restart, so socket evidence wins whenever the
    /// server advertises it. Older servers fall back to the terminal environment.
    static func resolve(
        environment: [String: String],
        socketCapabilities: [String: Any]
    ) -> AgentCmuxRuntimeIdentity? {
        if let id = normalized(socketCapabilities["runtime_id"] as? String) {
            return AgentCmuxRuntimeIdentity(
                id: id,
                socketPath: normalized(socketCapabilities["socket_path"] as? String),
                bundleIdentifier: normalized(socketCapabilities["bundle_identifier"] as? String)
            )
        }
        return AgentCmuxRuntimeIdentity(environment: environment)
    }

    func applying(to environment: [String: String]) -> [String: String] {
        var result = environment
        result["CMUX_RUNTIME_ID"] = id
        if let socketPath { result["CMUX_SOCKET_PATH"] = socketPath }
        if let bundleIdentifier { result["CMUX_BUNDLE_ID"] = bundleIdentifier }
        return result
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

    /// The default view is an operational inventory, not a history log. Keep
    /// hibernated and restoring sessions visible because cmux still owns their
    /// lifecycle, while completed runs remain available through `--all`.
    func includes(projection: AgentSessionStateProjection) -> Bool {
        switch self {
        case .history:
            return true
        case .currentRuntime, .legacyUnscoped:
            return projection.effective != .ended
        }
    }
}
