import Foundation

/// A saved environment: a name for where a New Tab chat starts. A machine (this Mac or an SSH
/// acpmux peer), a folder on it and, on this Mac, whether each chat gets a new git worktree of that
/// folder. The New Tab page edits them (``AgentPaneEnvironmentRequest``) and the App keeps them on
/// this Mac (``SavedEnvironments``). Every field comes from the page, so ``validated()`` holds the
/// contract's caps before anything is kept.
public nonisolated struct AgentPaneEnvironment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, ssh }

    /// Host-assigned UUID; nil on a first save.
    public var id: String?
    public var name: String
    public var kind: Kind
    /// Kind `ssh`: the acpmux peer name, as the environment picker lists it.
    public var host: String?
    /// The folder the chat starts in: on this Mac for `local`, on the peer for `ssh`.
    public var folder: String?
    /// Kind `local` with a folder: each chat starts in a new git worktree of it.
    public var worktree: Bool?
    /// Milliseconds since 1970, set by the host on save.
    public var updatedAt: Int64?

    public init(id: String? = nil, name: String, kind: Kind, host: String? = nil, folder: String? = nil,
                worktree: Bool? = nil, updatedAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.folder = folder
        self.worktree = worktree
        self.updatedAt = updatedAt
    }

    public static let maximumName = 80
    public static let maximumHost = 256
    /// The same cap as every other path the page sends (``AgentPaneReplyPaths``).
    public static let maximumPath = 4096

    /// The environment as kept: the name trimmed, each kind's own fields only (a local one has no
    /// host, an SSH one no worktree), every cap held. Nil when anything breaks the contract; the
    /// page gets the refusal and nothing is kept.
    public func validated() -> AgentPaneEnvironment? {
        func text(_ value: String, _ limit: Int) -> Bool { value.utf8.count <= limit && !value.utf8.contains(0) }
        var out = self
        out.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maximumName).contains(out.name.count), text(out.name, 4 * Self.maximumName) else { return nil }
        if let id { guard UUID(uuidString: id) != nil else { return nil } }
        if let folder {
            guard !folder.isEmpty, text(folder, Self.maximumPath),
                  folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/") else { return nil }
        }
        switch kind {
        case .ssh:
            guard let host, !host.isEmpty, text(host, Self.maximumHost), !host.contains(where: \.isWhitespace) else { return nil }
            out.worktree = nil
        case .local:
            out.host = nil
            out.worktree = folder != nil && worktree == true ? true : nil
        }
        return out
    }
}
