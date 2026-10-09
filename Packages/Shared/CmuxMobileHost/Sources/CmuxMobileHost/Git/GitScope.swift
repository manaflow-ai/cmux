import CmuxMobileWire
import Foundation

/// Where one git read may look (c13-viewers.md section 3): the request path
/// passed the files policy, and the repository either sits inside a shared
/// root (unrestricted) or contains it (diffs restricted to the root's
/// relative prefix).
struct GitScope: Sendable {
    /// The canonical request path the session host reads.
    var path: String
    /// The repository's top level, as the session host reported it.
    var repositoryRoot: String
    /// Repository-relative folder every diff path must stay in; nil when
    /// the whole repository is shared.
    var prefix: String?

    /// Resolves `raw`, asks the session host for the repository and derives
    /// the restriction. Returns the scope and the status it read.
    static func resolve(_ raw: String, policy: MobileFilePolicy, reader: any MobileGitReader) async throws
        -> (GitScope, GitStatusResult) {
        let resolved = try resolveRequest(raw, policy: policy)
        let status = try await GitReads.status(path: resolved.path, reader: reader)
        let repository = MobileFilePolicy.canonicalize(status.root) ?? status.root
        if (try? policy.resolveExisting(repository)) != nil {
            return (GitScope(path: resolved.path, repositoryRoot: status.root, prefix: nil), status)
        }
        let base = repository.hasSuffix("/") ? repository : repository + "/"
        guard resolved.root.path.hasPrefix(base) else { throw MobileDaemonError.gitForbidden("the repository is not shared") }
        let prefix = String(resolved.root.path.dropFirst(base.count))
        return (GitScope(path: resolved.path, repositoryRoot: status.root, prefix: prefix), status)
    }

    /// The files policy's answer, with its refusal named for this family.
    private static func resolveRequest(_ raw: String, policy: MobileFilePolicy) throws(MobileDaemonError) -> MobileFilePolicy.Resolved {
        switch Result(catching: { () throws(MobileDaemonError) in try policy.resolveExisting(raw) }) {
        case .success(let resolved):
            return resolved
        case .failure(let error):
            throw error.code == "files.forbidden" ? MobileDaemonError.gitForbidden(error.message) : error
        }
    }

    /// Validates the phone's `paths` and applies the prefix: every entry is
    /// a relative path without `.`/`..`, NUL or denied names, under the
    /// prefix when there is one. No entries with a prefix reads the prefix.
    func restrict(_ paths: [String]?, configuration: MobileGitConfiguration) throws(MobileDaemonError) -> [String]? {
        guard let paths else { return prefix.map { [$0] } }
        guard !paths.isEmpty, paths.count <= configuration.maxPaths else {
            throw MobileDaemonError.filesInvalid("paths must have 1 to \(configuration.maxPaths) entries")
        }
        for path in paths {
            guard Self.isPlainRelative(path) else { throw MobileDaemonError.gitForbidden("paths must stay inside the repository") }
            guard !Self.hasDeniedComponent(path) else { throw MobileDaemonError.gitForbidden() }
            if let prefix, !Self.isInside(path, prefix: prefix) { throw MobileDaemonError.gitForbidden() }
        }
        return paths
    }

    /// Whether a repository-relative path is served.
    func allows(_ path: String) -> Bool {
        guard Self.isPlainRelative(path), !Self.hasDeniedComponent(path) else { return false }
        return prefix.map { Self.isInside(path, prefix: $0) } ?? true
    }

    static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func hasDeniedComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { MobileFilePolicy.isDenied(String($0)) }
    }

    static func isInside(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}
