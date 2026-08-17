import Foundation

/// A test-only on-disk git repository skeleton for exercising the git-diff
/// invalidation watcher. Built by writing the metadata files
/// ``GitMetadataService`` reads (no `git` process). Removed on `deinit`.
final class GitRepositoryFixture {
    let root: URL
    let gitDirectory: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxsidebargit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
        gitDirectory = base.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates a working-tree file, which the watcher observes via the
    /// work-tree root path.
    func writeWorkingTreeFile(_ relativePath: String, contents: String) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
