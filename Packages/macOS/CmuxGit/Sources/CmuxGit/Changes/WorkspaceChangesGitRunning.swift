import Foundation

/// The subprocess seam used by ``WorkspaceChangesService``.
protocol WorkspaceChangesGitRunning: Sendable {
    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult
    func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) throws -> WorkspaceChangesGitResult
    func run(
        arguments: [String],
        in directory: URL,
        writingOutputTo destination: URL,
        maximumOutputByteCount: Int64
    ) throws -> WorkspaceChangesGitResult
}

extension WorkspaceChangesGitRunning {
    func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) throws -> WorkspaceChangesGitResult {
        let result = try run(arguments: arguments, in: directory)
        let limit = max(0, maximumOutputByteCount)
        guard result.output.count > limit else { return result }
        return WorkspaceChangesGitResult(
            output: Data(result.output.prefix(limit)),
            exitCode: result.exitCode,
            standardOutputWasTruncated: true
        )
    }

    func run(
        arguments: [String],
        in directory: URL,
        writingOutputTo destination: URL,
        maximumOutputByteCount: Int64
    ) throws -> WorkspaceChangesGitResult {
        let result = try run(arguments: arguments, in: directory)
        let limit = max(0, maximumOutputByteCount)
        let wasTruncated = Int64(result.output.count) > limit
        let output = Data(result.output.prefix(Int(min(limit, Int64(Int.max)))))
        try output.write(to: destination, options: .atomic)
        return WorkspaceChangesGitResult(
            output: Data(),
            exitCode: result.exitCode,
            standardOutputWasTruncated: wasTruncated
        )
    }
}
