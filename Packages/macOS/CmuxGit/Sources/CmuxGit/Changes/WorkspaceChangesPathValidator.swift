import Foundation

/// Validates and normalizes repository-relative paths at the RPC trust boundary.
struct WorkspaceChangesPathValidator {
    func validatedPath(_ path: String, repoRoot: String) throws -> String {
        guard !path.isEmpty,
              !path.contains("\0"),
              !(path as NSString).isAbsolutePath else {
            throw WorkspaceChangesServiceError.invalidPath
        }

        let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL
        let candidateURL = rootURL.appendingPathComponent(path).standardizedFileURL
        guard candidateURL != rootURL, contains(candidateURL, in: rootURL) else {
            throw WorkspaceChangesServiceError.invalidPath
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = candidateURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedCandidate, in: resolvedRoot),
              contains(resolvedParent, in: resolvedRoot) else {
            throw WorkspaceChangesServiceError.invalidPath
        }

        let rootPath = rootURL.path == "/" ? "/" : rootURL.path + "/"
        return String(candidateURL.path.dropFirst(rootPath.count))
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        if candidatePath == rootPath { return true }
        return candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}
