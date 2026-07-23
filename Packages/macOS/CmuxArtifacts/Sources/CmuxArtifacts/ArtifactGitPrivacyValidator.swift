import Foundation

/// Reuses one tracked-store decision while validating exact write paths in batches.
struct ArtifactGitPrivacyValidator: Sendable {
    let worktreeRoot: URL?
    let commandRunner: any ArtifactGitCommandRunning

    func storeIsUntracked(filesystemRoot: URL) async -> Bool {
        guard let worktreeRoot else { return true }
        guard let relativeCmuxPath = ArtifactPathResolver().relativePath(
            filesystemRoot,
            root: worktreeRoot
        ) else {
            return false
        }
        let trackedContentPathspecs = [
            ":(glob)\(relativeCmuxPath)/**/artifacts/**",
            ":(glob)\(relativeCmuxPath)/**/notes/**",
            ":(glob)\(relativeCmuxPath)/**/_session.json",
            ":(glob)\(relativeCmuxPath)/**/_workspace.json",
            ":(glob)\(relativeCmuxPath)/.metadata/**",
        ]
        guard let trackedResult = try? await commandRunner.run(
            arguments: [
                "-C", worktreeRoot.path,
                "ls-files", "-z", "--",
            ] + trackedContentPathspecs,
            standardInput: nil
        ), trackedResult.terminationStatus == 0 else {
            return false
        }
        return trackedResult.standardOutput.isEmpty
    }

    func permits(destinations: [URL]) async -> Bool {
        guard !destinations.isEmpty else { return false }
        guard let worktreeRoot else { return true }
        let resolver = ArtifactPathResolver()
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
        ), result.terminationStatus == 0 else {
            return false
        }
        let outputBytes = [UInt8](result.standardOutput)
        var ignoredPaths: Set<Data> = []
        for pathBytes in outputBytes.split(whereSeparator: { $0 == 0 }) {
            ignoredPaths.insert(Data(pathBytes))
        }
        return ignoredPaths == Set(encodedPaths)
    }
}
