@testable import CmuxNextApp
import CmuxNextFiles
import Foundation
import Testing

/// LAUNCH-NO-TCC-PROMPTS: the Files section roots itself at the focused terminal's folder with no
/// action from the person (a launch that restores the sidebar open, a `cd`). In a
/// privacy-protected folder (~/Downloads) it lists nothing and watches nothing until the person
/// asks (its Show Contents button); listing there would make macOS ask in cmux's name.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FileExplorerProtectedFolderTests {
    /// Counts the folders it was asked to list; lists the real disk.
    final class CountingLister: DirectoryListing, @unchecked Sendable {
        // Read and written on the main actor only (the model's calls), in this test.
        nonisolated(unsafe) var listed: [URL] = []
        let real = DirectoryLister()
        func list(_ folder: URL) async throws -> [FileEntry] {
            listed.append(folder.standardizedFileURL)
            return try await real.list(folder)
        }
        func entry(at url: URL) async -> FileEntry? { await real.entry(at: url) }
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("a.txt"))
        return url.standardizedFileURL
    }

    @Test func aProtectedFolderIsNotListedUntilThePersonAsks() async throws {
        let guarded = try Self.folder(), plain = try Self.folder()
        let lister = CountingLister()
        let model = FileExplorerModel(lister: lister, isProtected: { $0.standardizedFileURL == guarded })
        await model.setRoot(guarded)
        #expect(model.root == guarded)
        #expect(model.held)
        #expect(model.rows.isEmpty)
        #expect(lister.listed.isEmpty, "listed a protected folder unasked: \(lister.listed)")
        // A watcher's reload lists nothing either.
        await model.reload()
        #expect(lister.listed.isEmpty)

        // The person asks: it lists, and later automatic roots there list too.
        await model.setRoot(guarded, asked: true)
        #expect(!model.held)
        #expect(model.rows.map(\.name) == ["a.txt"])
        await model.setRoot(plain)
        await model.setRoot(guarded)
        #expect(!model.held)

        // An ordinary folder lists at once.
        await model.setRoot(plain)
        #expect(!model.held)
        #expect(lister.listed.contains(plain))
    }

    @Test func theDefaultCheckKnowsDownloadsByItsSpelling() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FileExplorerModel.inProtectedFolder(home.appendingPathComponent("Downloads/project")))
        #expect(FileExplorerModel.inProtectedFolder(home.appendingPathComponent("Desktop")))
        #expect(!FileExplorerModel.inProtectedFolder(home.appendingPathComponent("code/cmux")))
        #expect(!FileExplorerModel.inProtectedFolder(FileManager.default.temporaryDirectory))
    }
}
