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
        _ = try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: scratch.root)], in: webView) { readAccess in
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

    /// The browser opens the file after `loadFileURL` returns. Before
    /// macOS 27, WebKit's processes may read the user's temporary directory
    /// whatever directory a load was granted, so a link another session
    /// renames in once the grant is taken (the rename lock is free again)
    /// must not lead the load there either.
    @Test("A link swapped in below the root after the load started reaches nothing outside it")
    func aLinkSwappedInAfterTheLoadStartedReadsNothingOutside() async throws {
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
        _ = try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: scratch.root)], in: webView) { readAccess in
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
        try manager.moveItem(atPath: scratch.root + "/site", toPath: scratch.root + "/site-old")
        try manager.createSymbolicLink(atPath: scratch.root + "/site", withDestinationPath: scratch.outside)
        await waiter.wait()
        let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
        #expect(text?.contains("outside secret") != true, "the load read a file outside the session's directories through a link swapped in after it started")
    }

    /// WebKit loads a history item (back, forward), a reload or a
    /// restored page itself, without the driver's check. A link another
    /// session swapped in below the root since the page first loaded must
    /// not lead such a load outside the session's directories either.
    @Test("Going back to, or reloading, a session's file page after a link was swapped in below the root reads nothing outside it")
    func aHistoryLoadAfterALinkSwapReadsNothingOutside() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        try Data("<p>other page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/other.html"))
        try Data("<p>outside secret</p>".utf8).write(to: URL(fileURLWithPath: scratch.outside + "/index.html"))
        let roots = [BrowserReplFileRoot(path: scratch.root)]
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        func load(_ path: String) async throws {
            let waiter = FileLoadWaiter(roots: roots)
            webView.navigationDelegate = waiter
            let url = URL(fileURLWithPath: scratch.root + path)
            _ = try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: roots, in: webView) { readAccess in
                webView.loadFileURL(url, allowingReadAccessTo: readAccess)
            }
            await waiter.wait()
        }
        func replay(_ start: (WKWebView) -> WKNavigation?) async -> String? {
            let waiter = FileLoadWaiter(roots: roots)
            webView.navigationDelegate = waiter
            if start(webView) != nil { await waiter.wait() }
            return try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
        }
        try await load("/site/index.html")
        try await load("/other.html")
        // Another session moves the page's directory away and a link to a
        // directory outside takes its name.
        try manager.moveItem(atPath: scratch.root + "/site", toPath: scratch.root + "/site-old")
        try manager.createSymbolicLink(atPath: scratch.root + "/site", withDestinationPath: scratch.outside)
        let back = await replay { $0.goBack() }
        #expect(back?.contains("outside secret") != true, "going back read a file outside the session's directories through the swapped link")
        let reloaded = await replay { $0.reload() }
        #expect(reloaded?.contains("outside secret") != true, "a reload read a file outside the session's directories through the swapped link")
    }

    @Test("A pinned load with nothing renamed shows its own page")
    func aPinnedLoadWithNothingRenamedShowsItsPage() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        let url = URL(fileURLWithPath: scratch.root + "/site/index.html")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let waiter = FileLoadWaiter()
        webView.navigationDelegate = waiter
        _ = try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: scratch.root)], in: webView) { readAccess in
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
        await waiter.wait()
        let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
        #expect(text == "own page", "\(String(describing: text))")
    }

    /// A rename another session runs while the browser opens the file, and
    /// one that puts the entry back before the response, leave the path as
    /// the check found it; the browser may have opened the file through a
    /// link meanwhile, so the response is refused.
    @Test("A pinned load's response is refused after any REPL rename, or with a link on its path")
    func aPinnedResponseIsRefusedAfterARenameOrThroughALink() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        let url = URL(fileURLWithPath: scratch.root + "/site/index.html")
        let roots = [BrowserReplFileRoot(path: scratch.root)]
        func pin() throws -> BrowserReplPinnedFileLoad {
            try BrowserReplFileSandbox.pinnedFileAccess(url.absoluteString, roots: roots) { $0 }
        }
        #expect(try pin().admitsResponse(url), "a response with nothing renamed was refused")

        // Another session's fs.rename, then one that puts the entry back.
        let fileSystem = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root))
        let renamed = try pin()
        _ = try fileSystem.perform("rename", arguments: ["from": "site", "to": "site-old"]).get()
        _ = try fileSystem.perform("rename", arguments: ["from": "site-old", "to": "site"]).get()
        #expect(manager.fileExists(atPath: scratch.root + "/site/index.html"))
        #expect(!renamed.admitsResponse(url), "a response after a rename and back was admitted")

        // A link on the path, put there without any REPL rename.
        let linked = try pin()
        try manager.moveItem(atPath: scratch.root + "/site", toPath: scratch.root + "/site-old")
        try manager.createSymbolicLink(atPath: scratch.root + "/site", withDestinationPath: scratch.outside)
        #expect(!linked.admitsResponse(url), "a response through a link was admitted")
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
    /// A child frame loads its file by path too, after its navigation is
    /// decided. Before macOS 27, a link another session swaps in below the
    /// root after the frame's navigation was checked, or before a reload of
    /// the frame, must not lead the frame outside the session's directories.
    @Test("A child frame's file load after a link was swapped in below the root reads nothing outside it")
    func aChildFrameLoadAfterALinkSwapReadsNothingOutside() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/frame", withIntermediateDirectories: true)
        try Data(#"<iframe src="frame/inner.html"></iframe>"#.utf8).write(to: URL(fileURLWithPath: scratch.root + "/index.html"))
        try Data("<p>own frame</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/frame/inner.html"))
        try Data("<p>outside secret</p>".utf8).write(to: URL(fileURLWithPath: scratch.outside + "/inner.html"))
        let roots = [BrowserReplFileRoot(path: scratch.root)]
        let url = URL(fileURLWithPath: scratch.root + "/index.html")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let waiter = FileLoadWaiter(roots: roots)
        webView.navigationDelegate = waiter
        _ = try BrowserReplFileSandbox.withPinnedFileAccess(url.absoluteString, roots: roots, in: webView) { readAccess in
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
        await waiter.wait()
        /// What the child frame shows now.
        func frameText() async -> String? {
            guard let frame = waiter.childFrame else { return nil }
            return try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''", in: frame, contentWorld: .page) as? String
        }
        let first = await frameText()
        #expect(first?.contains("own frame") == true, "the frame did not show its own page: \(String(describing: first))")

        /// Reloads the frame and returns what it shows once it loaded, or
        /// `nil` when its navigation or response was refused. WebKit itself
        /// may refuse the file outside its grant with no response to judge
        /// and no `load` event (macOS 27): after 10 s with neither, what the
        /// frame shows then is read (on macOS 26 the swapped file loads in
        /// well under a second when nothing refuses it).
        func reloadFrame(_ query: String) async throws -> String? {
            waiter.onChildFrameRefused = {
                webView.evaluateJavaScript("window.frameRefused && frameRefused()", completionHandler: nil)
            }
            let outcome = try await webView.callAsyncJavaScript("""
                const frame = document.querySelector('iframe')
                const done = new Promise(resolve => {
                    frame.addEventListener('load', () => resolve('loaded'), { once: true })
                    window.frameRefused = () => resolve('refused')
                    setTimeout(() => resolve('unsettled'), 10000)
                })
                frame.src = 'frame/inner.html?\(query)'
                return await done
                """, contentWorld: .page) as? String
            return outcome == "refused" ? nil : await frameText()
        }
        // Another session moves the frame's directory away and a link to a
        // directory outside takes its name, after the frame's navigation
        // was decided and before the browser opens the file.
        waiter.afterChildFrameDecision = {
            try? manager.moveItem(atPath: scratch.root + "/frame", toPath: scratch.root + "/frame-old")
            try? manager.createSymbolicLink(atPath: scratch.root + "/frame", withDestinationPath: scratch.outside)
        }
        let swappedAfterDecision = try await reloadFrame("after-decision")
        #expect(swappedAfterDecision?.contains("outside secret") != true, "the frame read a file outside the session's directories through a link swapped in after its navigation was decided")
        waiter.afterChildFrameDecision = nil
        let swappedBefore = try await reloadFrame("after-swap")
        #expect(swappedBefore?.contains("outside secret") != true, "a reload of the frame read a file outside the session's directories through the swapped link")
    }

    /// The rename log is shared by every session: renames in one session's
    /// directories, however many, say nothing about a directory on another
    /// session's file path.
    @Test("Many REPL renames in one root do not refuse a pinned load in another")
    func manyRenamesInOneRootDoNotRefuseAnother() throws {
        let busy = try Scratch()
        defer { busy.remove() }
        let quiet = try Scratch()
        defer { quiet.remove() }
        try FileManager.default.createDirectory(atPath: quiet.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: quiet.root + "/site/index.html"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: busy.root + "/a"))
        let url = URL(fileURLWithPath: quiet.root + "/site/index.html")
        let pin = try BrowserReplFileSandbox.pinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: quiet.root)]) { $0 }
        let fileSystem = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: busy.root))
        for _ in 0..<1500 {
            _ = try fileSystem.perform("rename", arguments: ["from": "a", "to": "b"]).get()
            _ = try fileSystem.perform("rename", arguments: ["from": "b", "to": "a"]).get()
        }
        #expect(pin.admitsResponse(url), "renames in another root refused a pinned load")
    }

    /// However many directories REPL renames touch after it, a rename in a
    /// directory on a pinned file's path still refuses its response.
    @Test("A rename on a pinned file's path refuses it after renames in many other directories of its root")
    func aRenameOnThePathRefusesAfterManyOtherDirectories() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        try manager.createDirectory(atPath: scratch.root + "/site", withIntermediateDirectories: true)
        try Data("<p>own page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/index.html"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: scratch.root + "/site/a"))
        for index in 0..<1500 {
            try manager.createDirectory(atPath: scratch.root + "/d\(index)", withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: scratch.root + "/d\(index)/a"))
        }
        let url = URL(fileURLWithPath: scratch.root + "/site/index.html")
        let pin = try BrowserReplFileSandbox.pinnedFileAccess(url.absoluteString, roots: [BrowserReplFileRoot(path: scratch.root)]) { $0 }
        let fileSystem = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root))
        _ = try fileSystem.perform("rename", arguments: ["from": "site/a", "to": "site/b"]).get()
        for index in 0..<1500 {
            _ = try fileSystem.perform("rename", arguments: ["from": "d\(index)/a", "to": "d\(index)/b"]).get()
        }
        #expect(!pin.admitsResponse(url), "a rename on the pinned file's path was forgotten after renames in other directories")
    }

}

/// Resumes once the main frame's load finished, failed or was refused.
/// With `roots`, it governs the web view's file loads as the app's
/// navigation delegate does for a tab a session created: every file
/// navigation of a frame is pinned when it is decided, and refused when the
/// check refuses it.
@MainActor
final class FileLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false
    private let roots: [BrowserReplFileRoot]?
    /// Runs once a child frame's file navigation was pinned and allowed,
    /// before the browser opens the file.
    var afterChildFrameDecision: (() -> Void)?
    /// The child frame whose file navigation was decided last.
    private(set) var childFrame: WKFrameInfo?
    /// Runs when a child frame's file navigation or response is refused.
    var onChildFrameRefused: (() -> Void)?
    init(roots: [BrowserReplFileRoot]? = nil) {
        self.roots = roots
    }

    func wait() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }

    private func finish() {
        done = true
        continuation?.resume()
        continuation = nil
    }

    /// Pins a frame's file navigation as the app's navigation delegate
    /// does (``BrowserReplPinnedFileLoads/pinNavigation(to:isMainFrame:roots:in:)``).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let roots, let frame = navigationAction.targetFrame,
              let url = navigationAction.request.url, url.isFileURL else {
            decisionHandler(.allow)
            return
        }
        do {
            try BrowserReplPinnedFileLoads.shared.pinNavigation(to: url, isMainFrame: frame.isMainFrame, roots: roots, in: webView)
            decisionHandler(.allow)
            if !frame.isMainFrame {
                childFrame = frame
                afterChildFrameDecision?()
            }
        } catch {
            decisionHandler(.cancel)
            if frame.isMainFrame { finish() } else { onChildFrameRefused?() }
        }
    }

    /// Admits a frame's response as the app's navigation delegate does
    /// (``BrowserReplPinnedFileLoads``).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let admitted = BrowserReplPinnedFileLoads.shared.admitsResponse(
            navigationResponse.response,
            isForMainFrame: navigationResponse.isForMainFrame,
            governed: roots != nil,
            in: webView
        )
        decisionHandler(admitted ? .allow : .cancel)
        if !admitted, !navigationResponse.isForMainFrame { onChildFrameRefused?() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }
}
