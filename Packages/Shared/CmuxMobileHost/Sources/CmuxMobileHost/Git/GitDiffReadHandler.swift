import CmuxMobileWire

/// `read git.diff`: changed files of a shared folder's repository and,
/// with `include_patch`, their patches; restricted to the shared prefix,
/// without denied names, bounded to one frame.
public struct GitDiffReadHandler: MobileReadHandler {
    let files: MobileFilesConfiguration
    let configuration: MobileGitConfiguration
    let roots: any MobileFileRootsProvider
    let reader: any MobileGitReader

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        guard let params = try? frame.params.decode(as: GitDiffParams.self) else {
            throw MobileDaemonError.filesInvalid("bad git.diff params")
        }
        let policy = MobileFilePolicy(configuration: files, roots: await roots.roots(for: principal))
        let (scope, _) = try await GitScope.resolve(params.path, policy: policy, reader: reader)
        let request = GitDiffParams(
            path: scope.path, scope: params.scope, paths: try scope.restrict(params.paths, configuration: configuration),
            includePatch: params.includePatch ?? false,
            maxPatchBytes: min(max(1, params.maxPatchBytes ?? configuration.maxPatchBytes), configuration.maxPatchBytes),
            maxFiles: min(max(1, params.maxFiles ?? configuration.defaultMaxFiles), configuration.maxFiles))
        let result = Self.filter(try await GitReads.diff(request, reader: reader), scope: scope)
        return try JSONValue(encoding: GitReplyBudget(maxBytes: configuration.maxReplyBytes).fit(result))
    }

    /// Drops files outside the scope or with a denied name (either side of
    /// a rename) and recomputes the totals from what is left.
    static func filter(_ result: GitDiffResult, scope: GitScope) -> GitDiffResult {
        let kept = result.files.filter { file in
            scope.allows(file.path) && (file.previousPath.map(scope.allows) ?? true)
        }
        guard kept.count != result.files.count else { return result }
        var filtered = result
        filtered.files = kept
        filtered.additions = kept.reduce(0) { $0 + $1.additions }
        filtered.deletions = kept.reduce(0) { $0 + $1.deletions }
        filtered.totalFiles = kept.count + result.filesOmitted
        return filtered
    }
}
