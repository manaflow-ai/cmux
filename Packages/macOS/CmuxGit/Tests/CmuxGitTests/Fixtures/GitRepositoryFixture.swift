import Foundation

/// A test-only on-disk git repository skeleton, built by writing the metadata
/// files ``GitMetadataService`` reads (no `git` process). Removed on `deinit`.
final class GitRepositoryFixture {
    let root: URL
    let gitDirectory: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
        gitDirectory = base.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `HEAD` pointing at `refs/heads/<branch>` and the loose ref value.
    func writeBranch(_ branch: String, commit: String = String(repeating: "f", count: 40)) throws {
        try "ref: refs/heads/\(branch)\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let refURL = gitDirectory.appendingPathComponent("refs/heads/\(branch)")
        try FileManager.default.createDirectory(
            at: refURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(commit)\n".write(to: refURL, atomically: true, encoding: .utf8)
    }

    /// Writes a detached `HEAD` holding a raw commit SHA.
    func writeDetachedHead(commit: String) throws {
        try "\(commit)\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Writes a `config` file body.
    func writeConfig(_ body: String) throws {
        try body.write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Writes the binary `index` from a fixture.
    func writeIndex(_ fixture: GitIndexFixture) throws {
        try fixture.data().write(to: gitDirectory.appendingPathComponent("index"))
    }

    /// Creates a tracked working-tree file and returns its `stat`-derived index
    /// entry so a matching (clean) index can be built.
    @discardableResult
    func writeWorkingTreeFile(_ relativePath: String, contents: String) throws -> GitIndexFixture.Entry {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var statValue = stat()
        _ = lstat(fileURL.path, &statValue)
        return GitIndexFixture.Entry(
            path: relativePath,
            mode: (statValue.st_mode & S_IXUSR) == 0 ? 0o100644 : 0o100755,
            mtimeSeconds: UInt32(truncatingIfNeeded: statValue.st_mtimespec.tv_sec),
            mtimeNanoseconds: UInt32(truncatingIfNeeded: statValue.st_mtimespec.tv_nsec),
            size: UInt32(truncatingIfNeeded: statValue.st_size)
        )
    }
}
