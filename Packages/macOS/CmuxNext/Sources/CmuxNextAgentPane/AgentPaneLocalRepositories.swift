public import CmuxNextCloud
public import Foundation

/// GitHub repositories picked as a new chat's folder on This Mac (`github:owner/name`): each cloned once into
/// `~/cmux/repos/github.com/OWNER/NAME` (`cmux link start-chat repo`), the folder the chat then starts in.
///
/// The composer asks for the clone the moment the repository is picked (`github.repos.prepare`), so it runs while the
/// person writes the first prompt; the `session/new` that names the repository (``AcpmuxPathPolicy/check(_:scope:)``)
/// awaits that same clone rather than starting a second one, and a later chat in it gets the folder at once. A clone
/// that failed is forgotten, so the next pick or send tries again; a folder removed since is cloned again.
public actor AgentPaneLocalRepositories {
    /// Clones `owner/name` (or finds its clone) and answers the folder; throws ``CloudMoveCLI/StartChatRepoRefusal``.
    public typealias Clone = @Sendable (_ repository: String) async throws -> String

    private let clone: Clone
    private let exists: @Sendable (String) -> Bool
    private var clones: [String: Task<String, any Error>] = [:]

    public init(clone: @escaping Clone, exists: @escaping @Sendable (String) -> Bool = AgentPaneLocalRepositories.isFolder) {
        (self.clone, self.exists) = (clone, exists)
    }

    /// The App's: the clone is cmux-tui's (`binary`), as `cmux chat --repo` makes one.
    public static func live(binary: URL) -> AgentPaneLocalRepositories {
        AgentPaneLocalRepositories { try await CloudMoveCLI(binary: binary).startChatRepo($0) }
    }

    /// The folder of `repository` (`owner/name`) on This Mac: the clone in flight or done, else a new one.
    public func folder(_ repository: String) async throws -> String {
        let key = repository.lowercased() // GitHub's names ignore case: one clone per repository
        if let task = clones[key] {
            // In flight or done: its answer, a failure too (the caller that started it forgets a failed one).
            let folder = try await task.value
            if exists(folder) { return folder }
            // Removed since it was cloned: a new clone, unless another caller started one meanwhile.
            if clones[key] == task { clones[key] = nil }
            return try await self.folder(repository)
        }
        let task = Task { [clone] in try await clone(repository) }
        clones[key] = task
        do {
            return try await task.value
        } catch {
            if clones[key] == task { clones[key] = nil }
            throw error
        }
    }

    public nonisolated static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
