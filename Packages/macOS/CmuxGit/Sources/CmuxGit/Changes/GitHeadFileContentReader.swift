import Foundation

/// Reads a file's content as committed at HEAD.
///
/// File Preview uses this as the base its gutter compares the buffer against.
/// Untracked files and files outside a repository return nil.
public struct GitHeadFileContentReader: Sendable {
    /// Largest HEAD content, in UTF-8 bytes, accepted as a base.
    public static let maximumContentByteCount = 2 * 1024 * 1024

    /// Shared by every reader so open editors do not each allocate a queue.
    private static let blockingGitQueue = DispatchQueue(
        label: "com.cmux.git-head-content",
        qos: .utility,
        attributes: .concurrent
    )

    private let runner: any WorkspaceChangesGitRunning

    public init() {
        runner = SystemWorkspaceChangesGitRunner()
    }

    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    /// Returns the HEAD content of the file at `absolutePath`.
    ///
    /// - Runs from the file's directory, so no repository-root lookup is needed.
    /// - `HEAD:./name` keeps the pathspec relative to that directory.
    /// - Any failure or oversized content returns nil.
    public func headContent(forFile absolutePath: String) async -> String? {
        guard let location = Self.location(ofFile: absolutePath) else { return nil }
        guard let output = await run(
            arguments: ["--literal-pathspecs", "show", "HEAD:./\(location.name)"],
            in: location.directory,
            maximumOutputByteCount: Self.maximumContentByteCount
        ) else { return nil }
        guard output.count <= Self.maximumContentByteCount else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    /// Returns the index path of the repository that owns the file.
    ///
    /// Watching it tells callers when a commit or stage invalidates the base.
    public func indexPath(forFile absolutePath: String) async -> String? {
        guard let location = Self.location(ofFile: absolutePath) else { return nil }
        guard let output = await run(
            arguments: ["rev-parse", "--absolute-git-dir"],
            in: location.directory,
            maximumOutputByteCount: 4096
        ) else { return nil }
        let gitDirectory = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("index")
            .path
    }

    /// Standard output of a run that exited with status 0.
    ///
    /// Truncated output cannot serve as a base, so it returns nil.
    private func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) async -> Data? {
        let runner = runner
        let result: WorkspaceChangesGitResult? = await withCheckedContinuation { continuation in
            Self.blockingGitQueue.async {
                continuation.resume(returning: try? runner.run(
                    arguments: arguments,
                    in: directory,
                    maximumOutputByteCount: maximumOutputByteCount,
                    wallTimeLimit: 5
                ))
            }
        }
        guard let result, result.exitCode == 0, !result.standardOutputWasTruncated else {
            return nil
        }
        return result.output
    }

    /// Splits a path into the run directory and the pathspec name.
    ///
    /// Relative paths and `.` or `..` names could escape the directory, so they are rejected.
    private static func location(ofFile absolutePath: String) -> (directory: URL, name: String)? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: absolutePath)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return (url.deletingLastPathComponent(), name)
    }
}
