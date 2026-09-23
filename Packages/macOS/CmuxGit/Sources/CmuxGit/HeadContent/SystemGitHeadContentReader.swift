public import Foundation

/// Reads committed file content with the system git executable.
///
/// Each call resolves symbolic links, then runs git from the file's own
/// directory with the directory-relative revision `HEAD:./name`, so no
/// repository-root lookup is needed. `git cat-file blob` returns the stored
/// bytes without textconv filters. Git runs through the bounded runner that
/// ``WorkspaceChangesService`` uses, off the cooperative thread pool.
///
/// ```swift
/// let reader: any GitHeadContentReading = SystemGitHeadContentReader()
/// let base = await reader.headContent(forFile: "/repo/Sources/App.swift")
/// ```
public struct SystemGitHeadContentReader: GitHeadContentReading {
    private let runner: any WorkspaceChangesGitRunning
    /// Largest HEAD content, in bytes, accepted as a base.
    private let maximumContentByteCount: Int
    /// Upper bound for one git invocation.
    private let gitWallTimeLimit: TimeInterval
    private let fileExists: @Sendable (String) -> Bool
    // Git subprocess waits block their thread until exit, so they run on this
    // queue instead of the Swift concurrency cooperative pool.
    private let blockingGitQueue = DispatchQueue(
        label: "com.cmux.git-head-content",
        qos: .utility,
        attributes: .concurrent
    )

    /// Creates a reader backed by the system git executable.
    public init() {
        self.init(runner: SystemWorkspaceChangesGitRunner())
    }

    init(
        runner: any WorkspaceChangesGitRunning,
        maximumContentByteCount: Int = 2 * 1024 * 1024,
        gitWallTimeLimit: TimeInterval = 5,
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.runner = runner
        self.maximumContentByteCount = maximumContentByteCount
        self.gitWallTimeLimit = gitWallTimeLimit
        self.fileExists = fileExists
    }

    /// Returns the bytes of a file as committed at HEAD.
    ///
    /// - Parameter absolutePath: The file's absolute path. Relative paths
    ///   return `nil`. A symbolic link reads the file it points to.
    /// - Returns: The committed bytes, or `nil` when the file is untracked,
    ///   outside a repository, larger than 2 MiB, or git fails.
    public func headContent(forFile absolutePath: String) async -> Data? {
        guard let location = Self.location(ofFile: absolutePath) else { return nil }
        return await run(
            arguments: ["cat-file", "blob", "HEAD:./\(location.name)"],
            in: location.directory,
            maximumOutputByteCount: maximumContentByteCount
        )
    }

    /// Returns the repository paths whose changes can move HEAD content.
    ///
    /// - Parameter absolutePath: The file's absolute path. Relative paths
    ///   return `nil`.
    /// - Returns: Existing absolute paths among `HEAD`, `index`, the
    ///   checked-out branch's loose ref, `packed-refs`, and `reftable`,
    ///   sorted, or `nil` outside a repository.
    public func watchedPaths(forFile absolutePath: String) async -> [String]? {
        guard let location = Self.location(ofFile: absolutePath),
              let directories = await run(
                  arguments: ["rev-parse", "--absolute-git-dir", "--git-common-dir"],
                  in: location.directory,
                  maximumOutputByteCount: 8192
              ) else { return nil }
        let lines = String(decoding: directories, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0) }
        guard lines.count == 2 else { return nil }
        let gitDirectory = URL(fileURLWithPath: lines[0], isDirectory: true)
        // `--git-common-dir` may be relative to the directory git ran in.
        let commonDirectory = URL(fileURLWithPath: lines[1], isDirectory: true, relativeTo: location.directory)
            .standardizedFileURL
        // Exits 1 on a detached HEAD, which has no branch ref to watch.
        let branchRef = await run(
            arguments: ["symbolic-ref", "-q", "HEAD"],
            in: location.directory,
            maximumOutputByteCount: 4096
        ).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

        var candidates = [
            gitDirectory.appendingPathComponent("HEAD"),
            gitDirectory.appendingPathComponent("index"),
            commonDirectory.appendingPathComponent("packed-refs"),
            commonDirectory.appendingPathComponent("reftable", isDirectory: true),
        ]
        if let branchRef, branchRef.hasPrefix("refs/") {
            candidates.append(commonDirectory.appendingPathComponent(branchRef))
        }
        let existing = Set(candidates.map(\.path).filter(fileExists))
        return existing.sorted()
    }

    /// Standard output of a run that exited with status 0.
    ///
    /// Truncated output cannot serve as a base, so it returns `nil`.
    private func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) async -> Data? {
        let runner = runner
        let wallTimeLimit = gitWallTimeLimit
        let result: WorkspaceChangesGitResult? = await withCheckedContinuation { continuation in
            blockingGitQueue.async {
                continuation.resume(returning: try? runner.run(
                    arguments: arguments,
                    in: directory,
                    maximumOutputByteCount: maximumOutputByteCount,
                    wallTimeLimit: wallTimeLimit
                ))
            }
        }
        guard let result, result.exitCode == 0, !result.standardOutputWasTruncated else {
            return nil
        }
        return result.output
    }

    /// Splits a path into the run directory and the file name git resolves
    /// against it.
    ///
    /// Symbolic links resolve first so git reads the file whose content the
    /// editor shows. Relative paths and `.` or `..` names could escape the
    /// directory, so they are rejected.
    private static func location(ofFile absolutePath: String) -> (directory: URL, name: String)? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return (url.deletingLastPathComponent(), name)
    }
}
