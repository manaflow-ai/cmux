import Foundation

@testable import CmuxArtifacts

/// Records Git privacy invocations without shared mutable test state.
struct ArtifactGitInvocationRecordingRunner: ArtifactGitCommandRunning {
    let logURL: URL

    func terminationStatus(arguments: [String]) throws -> Int32 {
        try record(mode: "status", arguments: arguments)
        return arguments.contains("ls-files") ? 1 : 0
    }

    func run(
        arguments: [String],
        standardInput: Data?
    ) throws -> (terminationStatus: Int32, standardOutput: Data) {
        try record(mode: "output", arguments: arguments)
        let output = arguments.contains("check-ignore") ? (standardInput ?? Data()) : Data()
        return (0, output)
    }

    private func record(mode: String, arguments: [String]) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let fields = [mode] + arguments
        try handle.write(contentsOf: Data((fields.joined(separator: "\u{1f}") + "\n").utf8))
        try handle.close()
    }
}
