import CmuxFoundation
import Foundation
import Testing

@testable import CmuxSwiftRenderUI

/// The cases where validation said "ok" for something that cannot render.
///
/// `cmux sidebar validate` exists so an author learns about a broken sidebar from the terminal
/// instead of from a blank pane, so a false pass is worse than no check at all.
@Suite("Custom sidebar web validation strictness")
struct CustomSidebarWebValidationStrictnessTests {
    private let validator = CustomSidebarValidator()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-strict-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    // "Exists" was the whole check for `.html`, and a directory exists.
    @Test("a directory named board.html does not validate as a document")
    func rejectsDirectoryDocument() throws {
        let dir = try directory()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("board.html"),
            withIntermediateDirectories: true
        )

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.errorCount == 1)
        #expect(report.entries.first?.isValid == false)
    }

    @Test("an unreadable document does not validate")
    func rejectsUnreadableDocument() throws {
        let dir = try directory()
        let fileURL = dir.appendingPathComponent("board.html")
        try write("<!doctype html>", to: dir, as: "board.html")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.entries.first?.isValid == false)
    }

    @Test("a readable document still validates")
    func acceptsReadableDocument() throws {
        let dir = try directory()
        try write("<!doctype html><title>Board</title>", to: dir, as: "board.html")

        #expect(validator.validate(directory: dir, name: "board").validCount == 1)
    }

    @Test("a FIFO named as an html document is rejected without waiting for a writer")
    func rejectsFIFODocument() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("board.html")
        try #require(mkfifo(fileURL.path, 0o600) == 0, "mkfifo failed with errno \(errno)")

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.entries.first?.errorMessage == "Failed to read sidebar file.")
    }

    @Test("a symlink to a readable html document still validates")
    func acceptsSymlinkedDocument() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("document")
        try "<!doctype html><title>Board</title>".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("board.html"),
            withDestinationURL: target
        )

        #expect(validator.validate(directory: dir, name: "board").validCount == 1)
    }

    @Test(
        "a url file naming a hostless target fails validation rather than mounting a blank page",
        arguments: ["http:", "https:", "http:///path"]
    )
    func rejectsHostlessURLTarget(target: String) throws {
        let dir = try directory()
        try write(target + "\n", to: dir, as: "board.url")

        #expect(validator.validate(directory: dir, name: "board").errorCount == 1)
    }

    // Discovery reads the disk; resolution builds `<name>.<ext>` from the lowercase list. If
    // discovery accepted `board.HTML`, the CLI would report a sidebar that select/open cannot find.
    @Test("an uppercase extension is not discovered as a sidebar")
    func ignoresUppercaseExtensions() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.HTML")

        #expect(validator.discover(in: dir).isEmpty)
    }
}
