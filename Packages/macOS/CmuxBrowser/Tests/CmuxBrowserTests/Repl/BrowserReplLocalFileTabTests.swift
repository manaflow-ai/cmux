import Foundation
import Testing

@testable import CmuxBrowser

/// A tab the user opened on a local file outside the session's directories
/// shows that file (and the browser lets its page read its directory), so
/// a session that drives the tab would read files its `fs` cannot. The
/// driver refuses the session's reads and input there, as on a page the
/// domain policy blocks (`localPageRefusal`).
@Suite("Browser REPL local-file tabs")
struct BrowserReplLocalFileTabTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    @Test("A tab that shows a file outside the session's directories is refused")
    func aFileOutsideTheRootsIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let roots = [scratch.root]
        let outside = URL(fileURLWithPath: scratch.outside + "/secret.txt").absoluteString
        let reason = try #require(BrowserReplFileSandbox.localPageRefusal(url: outside, documentOrigin: "file://", roots: roots))
        #expect(reason.contains(outside), "the refusal does not name the file: \(reason)")
        // Through a link inside the root, and by a path that climbs out of it.
        try FileManager.default.createSymbolicLink(atPath: scratch.root + "/link", withDestinationPath: scratch.outside)
        for url in [
            URL(fileURLWithPath: scratch.root + "/link/secret.txt").absoluteString,
            "file://" + scratch.root + "/../outside/secret.txt",
            "file:///etc/hosts",
        ] {
            #expect(BrowserReplFileSandbox.localPageRefusal(url: url, documentOrigin: "file://", roots: roots) != nil, "\(url) was not refused")
        }
    }

    @Test("A page a local file wrote into an about:blank or data: document is refused")
    func aDocumentOfAFileOriginIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        for url in ["about:blank", "data:text/html,x"] {
            #expect(BrowserReplFileSandbox.localPageRefusal(url: url, documentOrigin: "file://", roots: [scratch.root]) != nil, "\(url) of a file origin was not refused")
        }
    }

    @Test("Files inside the session's directories and web pages are not refused")
    func filesInsideTheRootsAndWebPagesPass() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data("<p>report</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/report.html"))
        let inside = URL(fileURLWithPath: scratch.root + "/report.html").absoluteString
        #expect(BrowserReplFileSandbox.localPageRefusal(url: inside, documentOrigin: "file://", roots: [scratch.root]) == nil)
        for url in ["https://example.com/", "about:blank", "data:text/html,x", ""] {
            #expect(BrowserReplFileSandbox.localPageRefusal(url: url, documentOrigin: nil, roots: [scratch.root]) == nil, "\(url)")
            #expect(BrowserReplFileSandbox.localPageRefusal(url: url, documentOrigin: "https://example.com", roots: [scratch.root]) == nil, "\(url)")
        }
    }
}
