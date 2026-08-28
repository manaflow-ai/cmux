import Foundation
import Testing

@testable import CmuxFoundation

/// A `.url` sidebar file is untrusted input with a bounded job: it names one page.
///
/// It arrives by drag-and-drop from a browser or by hand, so its size is not something cmux gets to
/// assume. Reading it whole into a `String` and then materialising every line means an arbitrarily
/// large file — a mis-dropped video, a log someone renamed — is fully resident in memory before
/// anything decides it is nonsense, and it is read on every resolution, which is every
/// `cmux sidebar reload` and every mount. A shortcut file that needs more than a few kilobytes is
/// not a shortcut file, so the reader stops rather than growing to fit.
///
/// The limit is behaviour, not an implementation detail: an oversized file must resolve to no
/// sidebar and must be *diagnosed*, so `cmux sidebar validate` says why instead of leaving the
/// author with a blank pane.
@Suite("Custom sidebar .url file bounds")
struct CustomSidebarURLFileBoundTests {
    /// The largest `.url` file cmux will read, in bytes.
    ///
    /// Spelled out here rather than read from the type under test: this is the number the behaviour
    /// is defined in terms of, so a test that took it from production would move with it silently.
    private static let limit = 64 * 1024

    private func withURLFile(_ contents: String, _ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-bound-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try body(fileURL)
    }

    /// A file of exactly `byteCount` bytes with a perfectly good URL on its first line.
    ///
    /// The URL comes first so a refusal cannot be blamed on the target: a reader that merely stopped
    /// early would still have found it. Refusing is a decision about the file's size.
    private func contents(byteCount: Int) -> String {
        let url = "http://127.0.0.1:8787/\n"
        return url + String(repeating: "#", count: byteCount - url.utf8.count)
    }

    @Test("a file past the size limit names no sidebar, even with a valid URL on its first line")
    func oversizedFileResolvesToNothing() {
        withURLFile(contents(byteCount: Self.limit + 1)) { fileURL in
            #expect(CustomSidebarWebSource.remoteURL(fromURLFile: fileURL) == nil)
            #expect(CustomSidebarSource.classify(fileURL: fileURL) == nil)
        }
    }

    @Test("an oversized file is diagnosed rather than silently mounting nothing")
    func oversizedFileIsDiagnosed() {
        withURLFile(contents(byteCount: Self.limit + 1)) { fileURL in
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == .tooLarge)
        }
    }

    /// The boundary is inclusive on the accepting side, so a file exactly at the limit still works
    /// and the rule is one an author can reason about.
    @Test("a file exactly at the limit is still read")
    func fileAtTheLimitIsAccepted() {
        withURLFile(contents(byteCount: Self.limit)) { fileURL in
            #expect(
                CustomSidebarWebSource.remoteURL(fromURLFile: fileURL)
                    == URL(string: "http://127.0.0.1:8787/")
            )
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == nil)
        }
    }

    /// The reader and the diagnoser must not disagree about the limit, or `cmux sidebar validate`
    /// approves a file the sidebar then refuses to mount.
    @Test("resolution and diagnosis agree across the boundary", arguments: [-1, 0, 1])
    func resolutionAndDiagnosisAgreeAtTheBoundary(offset: Int) {
        withURLFile(contents(byteCount: Self.limit + offset)) { fileURL in
            let resolved = CustomSidebarWebSource.remoteURL(fromURLFile: fileURL)
            let problem = CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL)
            #expect((resolved == nil) == (problem != nil))
        }
    }

    /// The limit is generous enough that no real shortcut file is near it: a browser-written
    /// `[InternetShortcut]` with a long URL and a pile of extra keys still fits comfortably.
    @Test("a realistic browser-written shortcut file is nowhere near the limit")
    func realisticShortcutFilesFit() {
        let contents = """
        [InternetShortcut]
        URL=http://127.0.0.1:8787/dashboard?\(String(repeating: "q=1&", count: 200))
        IconIndex=0
        IconFile=C:\\Windows\\System32\\shell32.dll
        HotKey=0
        """
        #expect(contents.utf8.count < Self.limit)
        withURLFile(contents) { fileURL in
            #expect(CustomSidebarWebSource.remoteURL(fromURLFile: fileURL) != nil)
            #expect(CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) == nil)
        }
    }

    /// The other half of bounding the read: a file under the limit must not be materialised line by
    /// line either. Leading noise ahead of the URL is the shape that built one `Substring` per line
    /// for the whole file; the answer has to stay correct however the bytes are walked.
    @Test("a URL after leading noise is still found within the bounded read")
    func urlAfterNoiseIsStillFound() {
        let contents = String(repeating: "# padding\n", count: 500) + "http://127.0.0.1:8787/\n"
        #expect(contents.utf8.count < Self.limit)
        withURLFile(contents) { fileURL in
            #expect(
                CustomSidebarWebSource.remoteURL(fromURLFile: fileURL)
                    == URL(string: "http://127.0.0.1:8787/")
            )
        }
    }
}
