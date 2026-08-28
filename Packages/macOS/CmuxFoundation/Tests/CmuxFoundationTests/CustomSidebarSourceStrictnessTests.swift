import Foundation
import Testing

@testable import CmuxFoundation

/// Covers the two ways a sidebar file can look valid and not be.
///
/// Both matter because classification decides what gets *rendered*: a source that classifies is one
/// the app will mount, so anything it accepts that the loader then refuses becomes a blank sidebar
/// with no explanation.
@Suite("Custom sidebar source strictness")
struct CustomSidebarSourceStrictnessTests {
    private func withURLFile(_ contents: String, _ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-strict-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try body(fileURL)
    }

    // `http:` parses as a URL and reports the right scheme, so a scheme-only check accepts it. There
    // is nothing to load: no host, so the web view renders nothing and the author sees a blank
    // sidebar rather than a validation error.
    @Test(
        "a hostless http(s) string is not a loadable target",
        arguments: [
            "http:",
            "https:",
            "http:///path",
            "https:///",
            "http://",
        ]
    )
    func rejectsHostlessTargets(contents: String) {
        withURLFile(contents + "\n") { fileURL in
            #expect(CustomSidebarWebSource.remoteURL(fromURLFile: fileURL) == nil)
            #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) != nil)
        }
    }

    @Test("a host-bearing target is still accepted")
    func acceptsHostBearingTargets() {
        withURLFile("http://127.0.0.1:8787/\n") { fileURL in
            #expect(CustomSidebarWebSource.remoteURL(fromURLFile: fileURL) != nil)
        }
    }

    // Resolution builds `<name>.<ext>` from a lowercase list while discovery reads what is on disk.
    // Case-folding the extension makes the two agree only on a case-insensitive volume; on a
    // case-sensitive one, discovery finds `board.HTML` and resolution then looks for `board.html`
    // and finds nothing. Refusing the uppercase form outright keeps them in agreement everywhere.
    @Test(
        "an uppercase extension is not a recognised sidebar source",
        arguments: ["board.HTML", "board.Html", "board.URL", "board.SWIFT", "board.JSON"]
    )
    func rejectsUppercaseExtensions(fileName: String) {
        let fileURL = URL(fileURLWithPath: "/sidebars/\(fileName)")
        #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
    }

    @Test(
        "the exact lowercase extensions are recognised",
        arguments: ["board.swift", "board.json", "board.html"]
    )
    func acceptsLowercaseExtensions(fileName: String) {
        let fileURL = URL(fileURLWithPath: "/sidebars/\(fileName)")
        #expect(CustomSidebarSource.classify(fileURL: fileURL) != nil)
    }
}
