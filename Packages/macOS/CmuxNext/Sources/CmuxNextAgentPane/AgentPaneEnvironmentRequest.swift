import Foundation

/// The New Tab page's saved environments (``AgentPaneEnvironment``). Fixed param keys (any other
/// key, at any depth, is refused, like ``AgentPaneReplyRequest``) and the environment's caps; only
/// a New Tab page gets them, never a chat.
///
/// - `environment.list {}` -> `{environments}`, the most recently saved first.
/// - `environment.save {environment}` -> `{environment}`, with the id and `updatedAt` the host
///   set; it replaces the one with the same id.
/// - `environment.remove {id}` -> `{}`.
///
/// User edits of app data, not file or command execution: no gesture.
public nonisolated enum AgentPaneEnvironmentRequest: Equatable, Sendable {
    case list
    case save(AgentPaneEnvironment)
    case remove(id: String)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = ["environment.list", "environment.save", "environment.remove"]

    static let knownParams: [String: Set<String>] = [
        "environment.list": [],
        "environment.save": ["environment"],
        "environment.remove": ["id"],
    ]
    private static let environmentKeys: Set<String> = ["id", "name", "kind", "host", "folder", "worktree", "updatedAt"]

    /// The request for `method` and `params`, nil when they break the contract.
    init?(method: String, params: [String: Any]?) {
        guard let known = Self.knownParams[method] else { return nil }
        let params = params ?? [:]
        guard Set(params.keys).isSubset(of: known) else { return nil }
        switch method {
        case "environment.list":
            self = .list
        case "environment.save":
            guard let environment = Self.environment(params["environment"]) else { return nil }
            self = .save(environment)
        case "environment.remove":
            guard let id = params["id"] as? String, UUID(uuidString: id) != nil else { return nil }
            self = .remove(id: id)
        default:
            return nil
        }
    }

    /// The page's environment object, checked key by key and then against its caps. The page's
    /// `updatedAt` is dropped: the host sets it.
    static func environment(_ raw: Any?) -> AgentPaneEnvironment? {
        guard var object = raw as? [String: Any], Set(object.keys).isSubset(of: environmentKeys) else { return nil }
        object = object.filter { !($0.value is NSNull) }
        object["updatedAt"] = nil
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let environment = try? JSONDecoder().decode(AgentPaneEnvironment.self, from: data) else { return nil }
        return environment.validated()
    }
}

/// The App's saved environments a New Tab page reads and edits (``AgentPaneStartFolders/environments``).
public nonisolated protocol AgentPaneEnvironmentStoring: Sendable {
    /// Every saved environment, the most recently saved first.
    func list() async -> [AgentPaneEnvironment]
    /// Keeps a validated environment, setting its id (when new) and `updatedAt`; returns it as kept.
    func save(_ environment: AgentPaneEnvironment) async throws -> AgentPaneEnvironment
    func remove(id: String) async throws
}

extension AgentPaneEnvironmentRequest {
    /// The page's reply: refused unless `newTabPage` (a New Tab page with no chat yet) and the
    /// App keeps environments.
    @MainActor
    func reply(store: (any AgentPaneEnvironmentStoring)?, newTabPage: Bool) async -> [String: Any] {
        guard newTabPage, let store else { return AgentPaneModel.unsupported(method) }
        do {
            switch self {
            case .list:
                return AgentPaneReply.success(["environments": try (await store.list()).map(Self.object)])
            case .save(let environment):
                return AgentPaneReply.success(["environment": try Self.object(await store.save(environment))])
            case .remove(let id):
                try await store.remove(id: id)
                return AgentPaneReply.success([String: Any]())
            }
        } catch {
            return AgentPaneReply.failure(code: "environment.failed", message: Self.failedMessage)
        }
    }

    var method: String {
        switch self {
        case .list: "environment.list"
        case .save: "environment.save"
        case .remove: "environment.remove"
        }
    }

    /// A save or remove could not be kept.
    static var failedMessage: String {
        String(localized: "agentPane.error.environment", defaultValue: "The saved environments could not be changed.", bundle: .module)
    }

    /// The JSON object the page reads; nil fields are left out.
    static func object(_ environment: AgentPaneEnvironment) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(environment))
    }
}
