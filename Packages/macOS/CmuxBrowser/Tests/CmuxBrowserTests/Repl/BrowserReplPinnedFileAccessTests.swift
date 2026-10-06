import AppKit
import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// The session checks a `file:` navigation's path (inside its directories,
/// no symbolic link below them), and the browser then loads it by path with
/// read access to a directory. Another REPL session that shares the
/// directory can rename entries in between: a link swapped in for a checked
/// directory must not lead the load, or the read access, outside the
/// session's directories (`withPinnedFileAccess`).
@MainActor
@Suite("Browser REPL pinned file navigation", .serialized)
struct BrowserReplPinnedFileAccessTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    @Test("A link swapped in below the root after the check reaches nothing outside it")
    func aLinkSwappedInAfterTheCheckReadsNothingOutside() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        try Data("<p>outside secret</p>".utf8).write(to: URL(fileURLWithPath: scratch.outside + "/index.html"))
        let url = URL(fileURLWithPath: scratch.root + "/site/index.html")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let waiter = FileLoadWaiter()
        webView.navigationDelegate = waiter
        try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: scratch.root)]) { readAccess in
            // Another session moves the checked directory away and a link
            // to a directory outside takes its name before the load starts.
            try manager.moveItem(atPath: scratch.root + "/site", toPath: scratch.root + "/site-old")
            try manager.createSymbolicLink(atPath: scratch.root + "/site", withDestinationPath: scratch.outside)
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
        await waiter.wait()
        let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
        #expect(text?.contains("outside secret") != true, "the load read a file outside the session's directories through the swapped link")
    }

    /// A tab's own loads of a session's file (a crashed web process's
    /// recovery, a discarded tab's restore, a reload, the page's links)
    /// start without the driver: they too take read access to the
    /// governing session's pinned root, checked under the rename lock, never
    /// the file's parent directory resolved through a link swapped in.
    @Test("A tab's own load of a session's file is pinned to the session's root through the board")
    func aTabsOwnLoadIsPinnedThroughTheBoard() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        let board = BrowserReplPolicyBoard()
        board.setFileRoots([scratch.root], sessionID: "s")
        let url = URL(fileURLWithPath: scratch.root + "/site/index.html")
        // The tab's creator governs its loads; in a user's tab, a session
        // attached to it governs a file inside its own directories.
        #expect(board.fileLoadSession(url, creator: "s", attached: ["s"]) == "s")
        #expect(board.fileLoadSession(url, creator: nil, attached: ["other", "s"]) == "s")
        #expect(board.fileLoadSession(URL(fileURLWithPath: scratch.outside + "/secret.txt"), creator: nil, attached: ["s"]) == nil)
        let granted = try board.withPinnedFileAccess(url.absoluteString, sessionID: "s") { $0 }
        #expect(granted.path == scratch.root, "the load was granted \(granted.path), not the session's root")
        // A link swapped in for a directory below the root refuses the load.
        try manager.moveItem(atPath: scratch.root + "/site", toPath: scratch.root + "/site-old")
        try manager.createSymbolicLink(atPath: scratch.root + "/site", withDestinationPath: scratch.outside)
        var loaded = false
        #expect(throws: BrowserReplDriverError.self) {
            try board.withPinnedFileAccess(url.absoluteString, sessionID: "s") { _ in loaded = true }
        }
        // A session without directories loads no file.
        #expect(throws: BrowserReplDriverError.self) {
            try board.withPinnedFileAccess(url.absoluteString, sessionID: "other") { _ in loaded = true }
        }
        #expect(!loaded)
    }

    @Test("A root whose path now names another directory, or a link, is refused")
    func aSwappedRootIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        let root = BrowserReplFileRoot(path: scratch.root)
        let url = URL(fileURLWithPath: scratch.root + "/index.html").absoluteString
        // Another directory takes the root's name.
        try manager.moveItem(atPath: scratch.root, toPath: scratch.base + "/work-old")
        try manager.createDirectory(atPath: scratch.root, withIntermediateDirectories: true)
        try Data("<p>other</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/index.html"))
        var loaded = false
        #expect(throws: BrowserReplDriverError.self) {
            try BrowserReplFileSandbox.withPinnedFileAccess(url, roots: [root]) { _ in loaded = true }
        }
        // A link to a directory outside takes the root's name.
        try manager.removeItem(atPath: scratch.root)
        try manager.createSymbolicLink(atPath: scratch.root, withDestinationPath: scratch.outside)
        #expect(throws: BrowserReplDriverError.self) {
            try BrowserReplFileSandbox.withPinnedFileAccess(url, roots: [root]) { _ in loaded = true }
        }
        #expect(!loaded, "the browser was told to load through a swapped root")
    }

    @Test("A file inside the root loads with read access to that root")
    func aFileInsideTheRootGetsTheRoot() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.root + "/a/b", withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: scratch.root + "/a/b/page.html").absoluteString
        let readAccess = try BrowserReplFileSandbox.withPinnedFileAccess(url, roots: [BrowserReplFileRoot(path: scratch.root)]) { $0 }
        #expect(readAccess.path == scratch.root, "read access went to \(readAccess.path), not the session's root")
    }
}

/// Resumes once the main frame's load finished or failed.
@MainActor
final class FileLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func wait() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }

    private func finish() {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }
}
