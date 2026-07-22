import Foundation

/// Reuses one tracked-store decision while validating exact write paths in batches.
struct ArtifactGitPrivacyValidator {
    let worktreeRoot: URL?
    let commandRunner: any ArtifactGitCommandRunning

    func permits(destinations: [URL]) -> Bool {
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
        guard let result = try? commandRunner.run(
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
