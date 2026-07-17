public import Foundation

/// A coding agent the Mac can dispatch, from `mobile.dispatch.catalog`.
public struct DispatchAgent: Identifiable, Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let installed: Bool

    public init(id: String, name: String, installed: Bool) {
        self.id = id
        self.name = name
        self.installed = installed
    }
}

/// A directory candidate from catalog recents or `mobile.dispatch.fs`.
public struct DispatchDirectory: Identifiable, Equatable, Sendable, Decodable {
    public var id: String { path }
    public let path: String
    public let git: Bool

    public init(path: String, git: Bool) {
        self.path = path
        self.git = git
    }

    /// The last path component, for row titles.
    public var name: String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case git
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        git = try container.decodeIfPresent(Bool.self, forKey: .git) ?? false
    }
}

/// The Mac's dispatch catalog: installed agents, recent project directories,
/// and the prompt size budget enforced by the launch RPC.
public struct DispatchCatalog: Equatable, Sendable, Decodable {
    public let home: String
    public let agents: [DispatchAgent]
    public let recentDirectories: [DispatchDirectory]
    public let promptByteBudget: Int

    public init(home: String, agents: [DispatchAgent], recentDirectories: [DispatchDirectory], promptByteBudget: Int) {
        self.home = home
        self.agents = agents
        self.recentDirectories = recentDirectories
        self.promptByteBudget = promptByteBudget
    }

    private enum CodingKeys: String, CodingKey {
        case home
        case agents
        case recentDirectories = "recent_dirs"
        case promptByteBudget = "prompt_byte_budget"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = try container.decode(String.self, forKey: .home)
        agents = try container.decodeIfPresent([DispatchAgent].self, forKey: .agents) ?? []
        recentDirectories = try container.decodeIfPresent([DispatchDirectory].self, forKey: .recentDirectories) ?? []
        promptByteBudget = try container.decodeIfPresent(Int.self, forKey: .promptByteBudget) ?? 900
    }

    public static func decode(_ data: Data) throws -> DispatchCatalog {
        try JSONDecoder().decode(DispatchCatalog.self, from: data)
    }
}

/// A non-fatal condition attached to an otherwise successful `mobile.dispatch.fs`
/// response (for example a macOS privacy denial for a protected folder).
public struct DispatchFSNotice: Equatable, Sendable, Decodable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var isPermissionDenied: Bool { code == "permission_denied" }
}

/// One level of directory browsing from `mobile.dispatch.fs` (`op: list`).
public struct DispatchFSList: Equatable, Sendable, Decodable {
    public let path: String
    public let entries: [DispatchDirectory]
    public let notice: DispatchFSNotice?
    public let truncated: Bool

    public init(path: String, entries: [DispatchDirectory], notice: DispatchFSNotice?, truncated: Bool) {
        self.path = path
        self.entries = entries
        self.notice = notice
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case entries
        case notice
        case truncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        entries = try container.decodeIfPresent([DispatchDirectory].self, forKey: .entries) ?? []
        notice = try container.decodeIfPresent(DispatchFSNotice.self, forKey: .notice)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public static func decode(_ data: Data) throws -> DispatchFSList {
        try JSONDecoder().decode(DispatchFSList.self, from: data)
    }
}

/// Ranked directory search results from `mobile.dispatch.fs` (`op: search`).
public struct DispatchFSSearch: Equatable, Sendable, Decodable {
    public let query: String
    public let entries: [DispatchDirectory]
    /// True while the Mac is still building its directory index; results may be partial.
    public let indexing: Bool
    public let truncated: Bool

    public init(query: String, entries: [DispatchDirectory], indexing: Bool, truncated: Bool) {
        self.query = query
        self.entries = entries
        self.indexing = indexing
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case entries
        case indexing
        case truncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        entries = try container.decodeIfPresent([DispatchDirectory].self, forKey: .entries) ?? []
        indexing = try container.decodeIfPresent(Bool.self, forKey: .indexing) ?? false
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public static func decode(_ data: Data) throws -> DispatchFSSearch {
        try JSONDecoder().decode(DispatchFSSearch.self, from: data)
    }
}

/// Why a dispatch launch failed, mapped from wire error codes so the composer
/// can stamp a concrete, localized rejection reason.
public enum DispatchLaunchFailure: Error, Equatable, Sendable {
    /// The target Mac was not connected when the launch was attempted.
    case notConnected
    /// The Mac did not answer before the request timeout expired.
    case requestTimedOut
    /// The request failed authorization against the target Mac.
    case authorizationFailed
    /// The chosen agent's CLI is not installed on the Mac.
    case agentNotInstalled
    /// The chosen project directory no longer exists on the Mac.
    case directoryNotFound
    /// The brief exceeds the Mac's prompt byte budget.
    case promptTooLong
    /// The Mac rejected the launch for another reason (developer message attached).
    case rejected(message: String?)
}

/// A saved, per-Mac composer draft so leaving the sheet never loses work.
public struct DispatchDraft: Equatable, Sendable, Codable {
    public var brief: String
    public var directoryPath: String?
    public var agentID: String?

    public init(brief: String = "", directoryPath: String? = nil, agentID: String? = nil) {
        self.brief = brief
        self.directoryPath = directoryPath
        self.agentID = agentID
    }

    public var isEmpty: Bool {
        brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && directoryPath == nil
            && agentID == nil
    }
}
