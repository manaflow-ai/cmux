import Foundation

/// Process-backed Git command runner used by the local artifact repository.
struct SystemArtifactGitCommandRunner: ArtifactGitCommandRunning {
    func terminationStatus(arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
