import Foundation

/// One Cloud environment as Settings draws it, decoded from a `cloud.environment.list` entry.
public nonisolated struct CloudEnvironmentRow: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// `owner/name[@ref]`, or nil for an environment without a repository.
    public var repo: String?
    public var setupScript: String
    /// CloudDO's status: unbuilt, building, ready, stale or failed (the page localizes it).
    public var status: String
    /// The last failed build's message and log tail; nil otherwise.
    public var error: String?
    public var logTail: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, repo, status, error
        case setupScript = "setup_script"
        case logTail = "log_tail"
        case lastBuild = "last_build"
    }

    /// CloudDO's `last_build`: only what a failed build tells the person.
    private struct Build: Decodable {
        struct Failure: Decodable { var message: String }
        var error: Failure?
        var logTail: String?
        private enum CodingKeys: String, CodingKey { case error, logTail = "log_tail" }
    }

    public init(id: String, name: String, repo: String? = nil, setupScript: String = "", status: String = "unbuilt", error: String? = nil, logTail: String? = nil) {
        self.id = id
        self.name = name
        self.repo = repo
        self.setupScript = setupScript
        self.status = status
        self.error = error
        self.logTail = logTail
    }

    /// Reads CloudDO's record (`last_build.error.message`, `last_build.log_tail`) or this row's own
    /// encoding (`error`, `log_tail`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        setupScript = try c.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unbuilt"
        let build = try c.decodeIfPresent(Build.self, forKey: .lastBuild)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? build?.error?.message
        logTail = try c.decodeIfPresent(String.self, forKey: .logTail) ?? build?.logTail
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(repo, forKey: .repo)
        try c.encode(setupScript, forKey: .setupScript)
        try c.encode(status, forKey: .status)
        try c.encode(error, forKey: .error)
        try c.encode(logTail, forKey: .logTail)
    }
}
