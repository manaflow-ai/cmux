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
