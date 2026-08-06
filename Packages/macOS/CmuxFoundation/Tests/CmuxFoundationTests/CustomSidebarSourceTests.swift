import Foundation
import Testing

@testable import CmuxFoundation

@Suite("CustomSidebarWebSource")
struct CustomSidebarWebSourceTests {
    private func withTemporaryFile(
        named name: String,
        contents: String,
        _ body: (URL) throws -> Void
    ) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-sidebar-web-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try body(fileURL)
    }

    @Test("classifies interpreted sources so existing sidebars keep rendering through the interpreter")
    func classifiesInterpretedSources() {
        let swiftURL = URL(fileURLWithPath: "/sidebars/board.swift")
        #expect(CustomSidebarSource.classify(fileURL: swiftURL) == .interpreted(swiftURL))

        let jsonURL = URL(fileURLWithPath: "/sidebars/board.json")
        #expect(CustomSidebarSource.classify(fileURL: jsonURL) == .interpreted(jsonURL))
    }

    @Test("classifies an html file as a local document")
    func classifiesHTMLDocument() {
        let htmlURL = URL(fileURLWithPath: "/sidebars/board.html")
        #expect(CustomSidebarSource.classify(fileURL: htmlURL) == .web(.document(htmlURL)))
    }

    @Test("reads a plain url file")
    func readsPlainURLFile() {
        withTemporaryFile(named: "board.url", contents: "http://127.0.0.1:8787/\n") { fileURL in
            #expect(
                CustomSidebarSource.classify(fileURL: fileURL)
                    == .web(.remote(URL(string: "http://127.0.0.1:8787/")!))
            )
        }
    }

    @Test("reads the URL key out of a Windows InternetShortcut file")
    func readsInternetShortcutFile() {
        let contents = "[InternetShortcut]\nURL=https://example.com/dashboard\nIconIndex=0\n"
        withTemporaryFile(named: "board.url", contents: contents) { fileURL in
            #expect(
                CustomSidebarSource.classify(fileURL: fileURL)
                    == .web(.remote(URL(string: "https://example.com/dashboard")!))
            )
        }
    }

    /// A `.url` file is dropped in by hand or by a browser, so it is untrusted input. A `file://`
    /// target would render arbitrary local content inside the app's own window, and a custom scheme
    /// could hand off to another application entirely.
    @Test("refuses non-http schemes in a url file")
    func refusesNonHTTPSchemes() {
        for scheme in ["file:///etc/passwd", "javascript:alert(1)", "cmux://open"] {
            withTemporaryFile(named: "board.url", contents: scheme) { fileURL in
                #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
            }
        }
    }

    @Test("treats an unreadable or empty url file as no sidebar rather than guessing")
    func handlesEmptyURLFile() {
        withTemporaryFile(named: "board.url", contents: "\n\n") { fileURL in
            #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
        }
        #expect(
            CustomSidebarSource.classify(fileURL: URL(fileURLWithPath: "/missing/board.url")) == nil
        )
    }

    @Test("does not classify an unrecognised extension")
    func ignoresUnknownExtensions() {
        #expect(CustomSidebarSource.classify(fileURL: URL(fileURLWithPath: "/s/board.txt")) == nil)
        // Backup files sit alongside real sidebars in the sidebars directory.
        #expect(
            CustomSidebarSource.classify(
                fileURL: URL(fileURLWithPath: "/s/board.swift.backup-2026-01-01")
            ) == nil
        )
    }
}
