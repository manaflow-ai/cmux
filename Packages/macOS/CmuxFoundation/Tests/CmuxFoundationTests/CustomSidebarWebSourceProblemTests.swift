import Foundation
import Testing

@testable import CmuxFoundation

@Suite("CustomSidebarWebSourceProblem")
struct CustomSidebarWebSourceProblemTests {
    private func withURLFile(_ contents: String, _ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-url-problem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try body(fileURL)
    }

    @Test(
        "a loadable url file reports no problem",
        arguments: [
            "http://127.0.0.1:8787/\n",
            "https://example.com/panel\n",
            "[InternetShortcut]\nURL=http://127.0.0.1:8787/\n",
            "# a comment\n\nhttp://127.0.0.1:8787/\n",
        ]
    )
    func loadableFilesHaveNoProblem(contents: String) {
        withURLFile(contents) { fileURL in
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == nil)
        }
    }

    @Test("a rejected scheme is named so the author knows what to change")
    func namesRejectedScheme() {
        withURLFile("file:///etc/passwd\n") { fileURL in
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .unsupportedScheme("file"))
        }
        withURLFile("cmux-browser://open\n") { fileURL in
            #expect(
                CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .unsupportedScheme("cmux-browser")
            )
        }
    }

    @Test("a file with no url at all is distinguished from one with a bad url")
    func distinguishesEmptyFromRejected() {
        withURLFile("[InternetShortcut]\n# nothing\n") { fileURL in
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .noURL)
        }
    }

    @Test("a missing file is unreadable rather than empty")
    func missingFileIsUnreadable() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-absent-\(UUID().uuidString).url")
        #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .unreadable)
    }

    // The renderer and the validator must never disagree: a file that validates has to load, and a
    // file that fails validation has to be one the renderer would also refuse.
    @Test(
        "diagnosis agrees with what the renderer actually resolves",
        arguments: [
            "http://127.0.0.1:8787/\n",
            "https://example.com/\n",
            "[InternetShortcut]\nURL=http://127.0.0.1:8787/\n",
            "file:///etc/passwd\n",
            "cmux-browser://open\n",
            "[InternetShortcut]\n# nothing\n",
            "",
        ]
    )
    func diagnosisMatchesResolution(contents: String) {
        withURLFile(contents) { fileURL in
            let resolved = CustomSidebarWebSource.remoteURL(fromURLFile: fileURL)
            let problem = CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL)
            #expect((resolved == nil) == (problem != nil))
        }
    }
}
