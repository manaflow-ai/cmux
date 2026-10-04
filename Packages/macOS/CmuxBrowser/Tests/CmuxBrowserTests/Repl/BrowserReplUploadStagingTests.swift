import Foundation
import Testing

@testable import CmuxBrowser

/// A file chooser answer is written to disk only for a chooser the session
/// may answer, and only within bounds: an answer for another session's
/// chooser, a stale one, or one too large writes nothing.
@Suite("Browser REPL upload staging")
struct BrowserReplUploadStagingTests {
    /// A directory this test made, removed afterwards.
    private func withParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-upload-staging-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    private func entries(_ parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path)
    }

    private func file(_ name: String, _ text: String) -> [String: Any] {
        ["name": name, "base64": Data(text.utf8).base64EncodedString()]
    }

    @Test("An answer the session may not give writes nothing")
    func anUnauthorizedAnswerWritesNothing() throws {
        try withParent { parent in
            var asked = 0
            let staged = try BrowserReplUploadStaging(parent: parent).stage([file("a.txt", "secret")]) {
                asked += 1
                return false
            }
            #expect(staged == nil)
            #expect(asked == 1)
            let left = try entries(parent)
            #expect(left.isEmpty, "a refused answer left files on disk")
        }
    }

    @Test("An authorized answer is staged in its own directory")
    func anAuthorizedAnswerIsStaged() throws {
        try withParent { parent in
            let staged = try #require(try BrowserReplUploadStaging(parent: parent).stage([file("a.txt", "one"), file("../b.txt", "two")]) { true })
            #expect(staged.directory.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
            #expect(staged.urls.map(\.lastPathComponent) == ["a.txt", ".._b.txt"])
            let text = try String(contentsOf: staged.urls[1], encoding: .utf8)
            #expect(text == "two")
        }
    }

    @Test("Too many files, too many bytes or a malformed file writes nothing")
    func anOversizedOrMalformedAnswerWritesNothing() throws {
        try withParent { parent in
            let staging = BrowserReplUploadStaging(parent: parent)
            let tooMany = (0...BrowserReplUploadStaging.maximumFiles).map { file("f\($0)", "x") }
            #expect(throws: BrowserReplDriverError.self) { try staging.stage(tooMany) { true } }
            let big = Data(count: BrowserReplUploadStaging.maximumBytes / 2 + 1).base64EncodedString()
            #expect(throws: BrowserReplDriverError.self) {
                try staging.stage([["name": "a", "base64": big], ["name": "b", "base64": big]]) { true }
            }
            #expect(throws: BrowserReplDriverError.self) { try staging.stage([["name": "a", "base64": "not base64!"]]) { true } }
            let left = try entries(parent)
            #expect(left.isEmpty, "a refused answer left files on disk")
        }
    }
}
