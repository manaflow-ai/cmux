import Foundation

/// A saved environment (cx-ncc.104): a named set of folders, a machine and settings a new chat
/// starts with. The New Tab page edits them (``AgentPaneEnvironmentRequest``) and the App keeps
/// them on this Mac. Every field comes from the page, so ``validated()`` holds the contract's caps
/// before anything is kept.
public nonisolated struct AgentPaneEnvironment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, ssh, cloud }

    /// A folder the chat starts in (the first) or also gets; `worktree` asks for a new git
    /// worktree of it, on `branch` when given.
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var branch: String?
        public var worktree: Bool?

        public init(path: String, branch: String? = nil, worktree: Bool? = nil) {
            self.path = path
            self.branch = branch
            self.worktree = worktree
        }
    }

    public struct Variable: Codable, Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// A cmux Cloud machine's network: none, a domain allow list, or all.
    public struct Cloud: Codable, Equatable, Sendable {
        public enum Network: String, Codable, Sendable { case blocked = "none", limited, full }
        public var network: Network
        public var domains: [String]
        public var setup: String?

        public init(network: Network, domains: [String] = [], setup: String? = nil) {
            self.network = network
            self.domains = domains
            self.setup = setup
        }
    }

    /// Host-assigned UUID; nil on a first save.
    public var id: String?
    public var name: String
    public var kind: Kind
    /// Kind `ssh`: the acpmux peer name, as the Computer menu lists it.
    public var host: String?
    public var folders: [Folder]
    public var env: [Variable]
    public var cloud: Cloud?
    /// Milliseconds since 1970, set by the host on save.
    public var updatedAt: Int64?

    public init(id: String? = nil, name: String, kind: Kind, host: String? = nil, folders: [Folder] = [],
                env: [Variable] = [], cloud: Cloud? = nil, updatedAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.folders = folders
        self.env = env
        self.cloud = cloud
        self.updatedAt = updatedAt
    }

    public static let maximumName = 80
    public static let maximumFolders = 16
    public static let maximumVariables = 32
    public static let maximumKey = 128
    public static let maximumValue = 4096
    public static let maximumHost = 256
    /// The same cap as every other path the page sends (``AgentPaneReplyPaths``).
    public static let maximumPath = 4096
    public static let maximumBranch = 256
    public static let maximumDomains = 64
    public static let maximumDomain = 253
    public static let maximumSetup = 16 * 1024

    /// The environment as kept: the name trimmed, each kind's own fields only (a local one has no
    /// host or cloud, a cloud one no folders), every cap held. Nil when anything breaks the
    /// contract; the page gets the refusal, nothing is kept.
    public func validated() -> AgentPaneEnvironment? {
        func text(_ value: String, _ limit: Int) -> Bool { value.utf8.count <= limit && !value.utf8.contains(0) }
        var out = self
        out.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maximumName).contains(out.name.count), text(out.name, 4 * Self.maximumName) else { return nil }
        if let id { guard UUID(uuidString: id) != nil else { return nil } }
        switch kind {
        case .ssh:
            guard let host, !host.isEmpty, text(host, Self.maximumHost) else { return nil }
            out.cloud = nil
        case .local:
            out.host = nil
            out.cloud = nil
        case .cloud:
            guard let cloud, cloud.domains.count <= Self.maximumDomains,
                  cloud.domains.allSatisfy({ !$0.isEmpty && text($0, Self.maximumDomain) && !$0.contains(where: \.isWhitespace) }),
                  cloud.setup.map({ text($0, Self.maximumSetup) }) ?? true else { return nil }
            out.host = nil
            out.folders = []
        }
        guard out.folders.count <= Self.maximumFolders, out.folders.allSatisfy(Self.isValid) else { return nil }
        guard env.count <= Self.maximumVariables, Set(env.map(\.key)).count == env.count,
              env.allSatisfy({ Self.isKey($0.key) && text($0.value, Self.maximumValue) }) else { return nil }
        return out
    }

    /// An absolute path (or one from the home folder, `~/…`) and a branch name without spaces.
    private static func isValid(_ folder: Folder) -> Bool {
        let path = folder.path
        guard !path.isEmpty, path.utf8.count <= maximumPath, !path.utf8.contains(0),
              path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return false }
        guard let branch = folder.branch else { return true }
        return !branch.isEmpty && branch.utf8.count <= maximumBranch && !branch.contains(where: { $0.isWhitespace || $0 == "\0" })
    }

    /// `/^[A-Za-z_][A-Za-z0-9_]*$/`, at most ``maximumKey`` characters.
    static func isKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, bytes.count <= maximumKey else { return false }
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        return letter(first) && bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
    }
}
