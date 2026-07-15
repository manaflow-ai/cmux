import Foundation
import Testing
@testable import CmuxGit

extension GitMetadataServiceTests {
    @Test func watchedPathsRecurseIntoNestedSubmodules() throws {
        let parent = try GitRepositoryFixture()
        try parent.writeBranch("main")
        let commit = String(repeating: "2", count: 40)

        // parent -> vendor/mid -> vendor/mid/deep (gitlinks at two depths)
        let midRoot = parent.root.appendingPathComponent("vendor/mid", isDirectory: true)
        let midGit = midRoot.appendingPathComponent(".git", isDirectory: true)
        let deepRoot = midRoot.appendingPathComponent("deep", isDirectory: true)
        let deepGit = deepRoot.appendingPathComponent(".git", isDirectory: true)
        for dir in [midGit, deepGit] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("refs/heads"),
                withIntermediateDirectories: true
            )
            try "\(commit)\n".write(to: dir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
        // mid's index records deep as a gitlink; parent's records mid.
        try GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "deep", mode: 0o160000, objectID: commit, size: 0),
        ]).data().write(to: midGit.appendingPathComponent("index"))
        try parent.writeIndex(GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "vendor/mid", mode: 0o160000, objectID: commit, size: 0),
        ]))

        let paths = try #require(GitMetadataService.workspaceGitMetadataWatchedPaths(for: parent.root.path))
        #expect(paths.contains(midGit.appendingPathComponent("HEAD").standardizedFileURL.path))
        #expect(paths.contains(deepGit.appendingPathComponent("HEAD").standardizedFileURL.path),
                "nested submodule metadata must be watched")
    }

    // MARK: Execution contract

    /// Pins the SE-0338 contract the service relies on: a `nonisolated async`
    /// method awaited from the main actor runs on the global concurrent executor,
    /// not the main thread. If CmuxGit ever adopts `NonisolatedNonsendingByDefault`,
    /// this fails — annotate the reads `@concurrent` to restore off-main execution.
    @MainActor @Test func nonisolatedAsyncReadsRunOffTheMainThread() async {
        #expect(pthread_main_np() != 0) // we start on the main actor's thread
        let hopped = await GitMetadataService().executionHopsOffCallersThread()
        #expect(hopped, "nonisolated async must hop off the caller's thread (SE-0338)")
    }
}
