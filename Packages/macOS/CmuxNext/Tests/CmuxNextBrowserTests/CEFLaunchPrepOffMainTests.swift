@testable import CmuxNextBrowser
import Foundation
import Testing

/// The disk work before `CefInitialize` (the profile root, keeping the last run's log) runs off the main thread
/// from the preload, while the first window builds, so the start after the first frame does none of it (CMUX-571).
@MainActor struct CEFLaunchPrepOffMainTests {
    @Test func thePreloadKeepsTheLastLogBeforeAnyPageAsks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-launch-prep-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CEFProfileStorage(root: root.appending(path: "Chromium"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        try Data("last run".utf8).write(to: storage.logFile)

        let runtime = CEFRuntime(libraryLoader: { _ in .failure(.notEmbedded) }, storage: storage)
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)

        var kept = false
        for _ in 0..<200 where !kept {
            kept = FileManager.default.fileExists(atPath: storage.previousLogFile.path)
            if !kept { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(kept, "the last run's log is kept by the preload's off-main prep, not by a page's start")
        #expect(!FileManager.default.fileExists(atPath: storage.logFile.path))
        #expect(runtime.state == .loading, "no CefInitialize before a page asks")
    }
}
