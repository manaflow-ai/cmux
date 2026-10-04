import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// A browser tab opened from a terminal opens its dev server (#16620).
@Suite struct WorkingURLTests {
    @Test func theNewestLocalServerOnScreenWins() {
        let screen = """
        docs: https://example.com/guide
          ➜  Local:   http://localhost:5173/
        restarted on http://127.0.0.1:3000/app.
        """
        #expect(WorkingURL.devServer(in: screen) == URL(string: "http://127.0.0.1:3000/app"))
    }

    @Test func aBindAddressBecomesLocalhost() {
        #expect(WorkingURL.devServer(in: "listening on http://0.0.0.0:8080/") == URL(string: "http://localhost:8080/"))
    }

    @Test func noLocalServerMeansABlankTab() {
        #expect(WorkingURL.devServer(in: "see https://github.com/manaflow-ai/cmux/pull/1") == nil)
        #expect(WorkingURL.devServer(in: nil) == nil)
    }

    /// An agent's cwd comes from its page: only an absolute directory on
    /// this Mac starts a terminal there.
    @Test func anAgentsCwdMustBeALocalDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "working-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.txt")
        try Data().write(to: file)
        #expect(WorkingURL.isDirectory(directory.path))
        #expect(!WorkingURL.isDirectory(file.path))
        #expect(!WorkingURL.isDirectory(directory.appending(path: "missing").path))
        #expect(!WorkingURL.isDirectory("relative/dir"))
        #expect(!WorkingURL.isDirectory(""))
    }
}
