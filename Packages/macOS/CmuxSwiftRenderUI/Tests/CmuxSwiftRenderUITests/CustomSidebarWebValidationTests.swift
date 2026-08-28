import CmuxFoundation
import Foundation
import Testing

@testable import CmuxSwiftRenderUI

/// Covers the CLI seam every `cmux sidebar` subcommand resolves through.
///
/// `validate`, `reload`, `select`, and `open` all answer from one
/// ``CustomSidebarValidator`` report, so a name the validator cannot see is a name none of them can
/// act on. Before this, an HTML sidebar rendered correctly from the picker while the CLI insisted it
/// did not exist.
@Suite("Custom sidebar web-source validation")
struct CustomSidebarWebValidationTests {
    private let validator = CustomSidebarValidator()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-web-validation-\(UUID().uuidString)", isDirectory: true)
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

    @Test("an html sidebar is discovered rather than reported missing")
    func discoversHTMLSidebar() throws {
        let dir = try directory()
        try write("<!doctype html><title>Board</title>", to: dir, as: "board.html")

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.names == ["board"])
        #expect(report.validCount == 1)
        #expect(report.errorCount == 0)
        #expect(report.entries.first?.kind == .html)
        #expect(report.entries.first?.fileURL.lastPathComponent == "board.html")
    }

    @Test("a url sidebar naming an http page validates")
    func discoversURLSidebar() throws {
        let dir = try directory()
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.validCount == 1)
        #expect(report.entries.first?.kind == .url)
    }

    @Test("a windows InternetShortcut url file validates, since that is what a browser writes")
    func acceptsInternetShortcutForm() throws {
        let dir = try directory()
        try write("[InternetShortcut]\nURL=https://127.0.0.1:8443/panel\n", to: dir, as: "board.url")

        #expect(validator.validate(directory: dir, name: "board").validCount == 1)
    }

    // The blank-pane failure this exists to pre-empt: the file is there, the sidebar appears in the
    // picker, and nothing renders because the target was never loadable.
    @Test("a url file naming a rejected scheme reports that scheme")
    func reportsRejectedScheme() throws {
        let dir = try directory()
        try write("file:///etc/passwd\n", to: dir, as: "board.url")

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "Sidebar .url file must be http or https, not 'file'.")
    }

    @Test("an empty url file says so instead of failing silently")
    func reportsEmptyURLFile() throws {
        let dir = try directory()
        try write("[InternetShortcut]\n# nothing here\n", to: dir, as: "board.url")

        let report = validator.validate(directory: dir, name: "board")

        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "Sidebar .url file does not contain a URL.")
    }

    // Precedence has to match the render path exactly, or the CLI acts on a different file than the
    // one the user is looking at.
    @Test(
        "interpreted sources win over web sources of the same name",
        arguments: [
            (["board.swift", "board.json", "board.html", "board.url"], "board.swift"),
            (["board.json", "board.html", "board.url"], "board.json"),
            (["board.html", "board.url"], "board.html"),
            (["board.url"], "board.url"),
        ]
    )
    func interpretedSourcesTakePrecedence(files: [String], expected: String) throws {
        let dir = try directory()
        for file in files {
            switch (file as NSString).pathExtension {
            case "swift": try write("Text(\"Swift\")", to: dir, as: file)
            case "json": try write(#"{"version":1,"root":{"type":"text","text":"J"}}"#, to: dir, as: file)
            case "html": try write("<!doctype html>", to: dir, as: file)
            default: try write("http://127.0.0.1:8787/\n", to: dir, as: file)
            }
        }

        #expect(validator.discover(in: dir).map(\.lastPathComponent) == [expected])
    }

    @Test("a directory of mixed sidebars reports one entry per name")
    func reportsOneEntryPerName() throws {
        let dir = try directory()
        try write("Text(\"Swift\")", to: dir, as: "alpha.swift")
        try write("<!doctype html>", to: dir, as: "beta.html")
        try write("http://127.0.0.1:8787/\n", to: dir, as: "gamma.url")

        let report = validator.validate(directory: dir)

        #expect(report.names == ["alpha", "beta", "gamma"])
        #expect(report.validCount == 3)
    }

    // The old report invented a `<name>.json` that had never been written, sending an HTML sidebar
    // author to a path that should not exist.
    @Test("a missing name reports the file an author would create, not a fabricated json path")
    func missingNameDoesNotFabricateJSON() throws {
        let dir = try directory()

        let report = validator.validate(directory: dir, name: "absent")

        #expect(report.entries.first?.fileURL.lastPathComponent == "absent.swift")
        #expect(report.entries.first?.errorMessage == "Sidebar file is missing.")
    }

    @Test("an unrecognised extension is not discovered as a sidebar")
    func ignoresUnknownExtensions() throws {
        let dir = try directory()
        try write("not a sidebar", to: dir, as: "notes.txt")

        #expect(validator.discover(in: dir).isEmpty)
    }
}
