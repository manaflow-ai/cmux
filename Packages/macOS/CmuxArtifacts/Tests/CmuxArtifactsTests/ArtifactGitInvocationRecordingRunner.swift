import Foundation

@testable import CmuxArtifacts

/// Records Git privacy invocations without shared mutable test state.
struct ArtifactGitInvocationRecordingRunner: ArtifactGitCommandRunning {
    let logURL: URL

    func run(
        arguments: [String],
        standardInput: Data?
    ) throws -> (terminationStatus: Int32, standardOutput: Data) {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((arguments.joined(separator: "\u{1f}") + "\n").utf8))
        try handle.close()
        let output = arguments.contains("check-ignore") ? (standardInput ?? Data()) : Data()
        return (0, output)
    }
}
