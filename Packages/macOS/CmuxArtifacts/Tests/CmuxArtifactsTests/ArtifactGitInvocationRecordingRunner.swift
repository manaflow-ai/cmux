import Foundation

@testable import CmuxArtifacts

/// Records Git privacy invocations without shared mutable test state.
struct ArtifactGitInvocationRecordingRunner: ArtifactGitCommandRunning {
    let logURL: URL

    func terminationStatus(arguments: [String]) throws -> Int32 {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((arguments.joined(separator: "\u{1f}") + "\n").utf8))
        try handle.close()
        return arguments.contains("ls-files") ? 1 : 0
    }
}
