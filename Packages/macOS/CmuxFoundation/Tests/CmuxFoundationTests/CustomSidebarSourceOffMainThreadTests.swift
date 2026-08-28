import Foundation
import Testing

@testable import CmuxFoundation

/// Classifying a sidebar file must not read the filesystem on the main thread, and must not read it
/// at all until it has to.
///
/// A custom sidebar re-renders about once a second, and both hosting surfaces used to classify their
/// file from a SwiftUI view builder. For a `.url` sidebar that is a whole-file read plus a line scan
/// on the main thread on every pass — a stall the user feels as sidebar-wide jank, and one no amount
/// of caching downstream can undo, because the read sits in the render path itself.
@Suite("Custom sidebar classification off the main thread")
struct CustomSidebarSourceOffMainThreadTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-offmain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A FIFO is not a sidebar file, and a reader must not wait for a writer before discovering that.
    /// All three entry points return from the writerless fixture because the descriptor is opened
    /// nonblocking and rejected from its file type before any bytes are requested.
    @Test("a writerless FIFO .url source is rejected immediately as unreadable")
    func fifoURLIsRejected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        try #require(mkfifo(fileURL.path, 0o600) == 0, "mkfifo failed with errno \(errno)")

        #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
        #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .unreadable)
        #expect(await CustomSidebarSource.classifying(fileURL: fileURL) == nil)
    }

    @Test("a symlink to a regular .url file remains loadable")
    func symlinkToRegularURLIsAccepted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try "http://127.0.0.1:8787/\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("board.url")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(
            CustomSidebarWebSource.remoteURL(fromURLFile: link)
                == URL(string: "http://127.0.0.1:8787/")
        )
    }

    /// The non-blocking half: for every extension whose kind follows from its name, the answer must
    /// be available with no filesystem access. A file that does not exist at all still classifies,
    /// which is what proves nothing was read.
    @Test(
        "an extension that decides the kind classifies with no filesystem access",
        arguments: ["board.swift", "board.json", "board.html", "board.txt"]
    )
    func nonURLExtensionsNeedNoRead(name: String) {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/\(name)")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        switch CustomSidebarSource.classifyWithoutReading(fileURL: missing) {
        case let .decided(source):
            // The decided answer agrees with the blocking classifier.
            #expect(source == CustomSidebarSource.classify(fileURL: missing))
        case .needsURLFileRead:
            Issue.record("\(name) should not require reading the file")
        }
    }

    @Test("a .url file is the only kind that needs its bytes read")
    func urlExtensionNeedsARead() {
        let url = URL(fileURLWithPath: "/sidebars/board.url")
        #expect(CustomSidebarSource.classifyWithoutReading(fileURL: url) == .needsURLFileRead(url))
    }

    /// The async and blocking classifiers must never disagree, or the sidebar renders one thing and
    /// `cmux sidebar validate` reports another.
    @Test(
        "the non-blocking classifier agrees with the blocking one on every source shape",
        arguments: [
            ("board.swift", "Text(\"hi\")"),
            ("board.json", "{\"version\":1}"),
            ("board.html", "<!doctype html>"),
            ("board.url", "http://127.0.0.1:8787/"),
            ("board.url", "[InternetShortcut]\nURL=https://example.com/x\n"),
            ("board.url", "file:///etc/passwd"),
            ("board.url", ""),
            ("board.txt", "whatever"),
            ("board.HTML", "<!doctype html>"),
        ]
    )
    func asyncAgreesWithBlocking(name: String, contents: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(await CustomSidebarSource.classifying(fileURL: fileURL)
            == CustomSidebarSource.classify(fileURL: fileURL))
    }
}
