import Foundation

/// Reuses one tracked-store decision while validating exact write paths in batches.
struct ArtifactGitPrivacyValidator: Sendable {
    let worktreeRoot: URL?
    let commandRunner: any ArtifactGitCommandRunning
    // Only FileManager's thread-safe, stateless path queries are used through this immutable reference.
    nonisolated(unsafe) let fileManager: FileManager

    func storeIsUntracked(filesystemRoot: URL) async -> Bool {
        guard let worktreeRoot else { return true }
        guard let relativeCmuxPath = ArtifactPathResolver(fileManager: fileManager).relativePath(
            filesystemRoot,
            root: worktreeRoot
        ) else {
            return false
        }
        let trackedContentPathspecs = [":(literal)\(relativeCmuxPath)"]
            + ArtifactStorePaths.trackableControlFileNames.map {
                ":(exclude,literal)\(relativeCmuxPath)/\($0)"
            }
        guard let trackedStatus = try? await commandRunner.terminationStatus(
            arguments: [
                "-C", worktreeRoot.path,
                "ls-files", "--error-unmatch", "--",
            ] + trackedContentPathspecs
        ) else {
            return false
        }
        // Git exits 128 when a trusted `.git` marker is only partially
        // initialized. Treat that marker as a non-Git project rather than
        // rejecting every artifact write; malformed/symlinked metadata is
        // rejected before this validator is constructed.
        return trackedStatus == 1 || trackedStatus == 128
    }

    func permits(destinations: [URL]) async -> Bool {
        guard !destinations.isEmpty else { return false }
        guard let worktreeRoot else { return true }
        let resolver = ArtifactPathResolver(fileManager: fileManager)
        var encodedPaths: [Data] = []
        var seen: Set<Data> = []
        for destination in destinations {
            guard let relativePath = resolver.relativePath(destination, root: worktreeRoot) else {
                return false
            }
            let encodedPath = Data(relativePath.utf8)
            guard seen.insert(encodedPath).inserted else { continue }
            encodedPaths.append(encodedPath)
        }
        var standardInput = Data()
        for encodedPath in encodedPaths {
            standardInput.append(encodedPath)
            standardInput.append(0)
        }
        guard let result = try? await commandRunner.run(
            arguments: [
                "-C", worktreeRoot.path,
                "check-ignore", "-z", "--stdin",
            ],
            standardInput: standardInput
        ), result.terminationStatus == 0 || result.terminationStatus == 128 else {
            return false
        }
        guard result.terminationStatus == 0 else { return true }
        let outputBytes = [UInt8](result.standardOutput)
        var ignoredPaths: Set<Data> = []
        for pathBytes in outputBytes.split(whereSeparator: { $0 == 0 }) {
            ignoredPaths.insert(Data(pathBytes))
        }
        return ignoredPaths == Set(encodedPaths)
    }
}
