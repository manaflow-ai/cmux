import AppKit
import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// A page in a tab a session created loads only local files inside the
/// session's directories, whatever read access its web process holds (an
/// earlier load in a shared process, a grant wider than the session's
/// directories). These tests load a page with read access wider than the
/// session's root and require the session's content rules
/// (`BrowserReplFileSandbox.contentRules(roots:)`) to keep it from loading
/// files outside the root, while files inside still load.
@MainActor
@Suite("Browser REPL local-file content rules", .serialized)
struct BrowserReplFileContentRuleTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    static let page = """
        <p>main</p>
        <iframe src="inside.html"></iframe>
        <iframe src="../outside/secret.txt"></iframe>
        <iframe src="sub%2F..%2F..%2Foutside%2Fsecret.txt"></iframe>
        <img id=outside src="../outside/dot.svg"><img id=inside src="dot.svg">
        """

    @Test("Frames and images outside the session's directories do not load; those inside do")
    func filesOutsideTheRootDoNotLoad() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#
        try Data(svg.utf8).write(to: URL(fileURLWithPath: scratch.outside + "/dot.svg"))
        try Data(svg.utf8).write(to: URL(fileURLWithPath: scratch.root + "/dot.svg"))
        try Data("<p>inside page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/inside.html"))
        try Data(Self.page.utf8).write(to: URL(fileURLWithPath: scratch.root + "/page.html"))
        try FileManager.default.createDirectory(atPath: scratch.root + "/sub", withIntermediateDirectories: true)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(try await Self.compile(BrowserReplFileSandbox.contentRules(roots: [scratch.root])))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = FileLoadWaiter()
        webView.navigationDelegate = waiter
        // Read access wider than the session's root, as a web process that
        // holds an earlier grant has.
        webView.loadFileURL(URL(fileURLWithPath: scratch.root + "/page.html"), allowingReadAccessTo: URL(fileURLWithPath: scratch.base))
        await waiter.wait()

        var texts: [String] = []
        for frame in await BrowserReplFrame.readTree(of: webView).dropFirst() {
            let text = try? await webView.callAsyncJavaScript("return document.body ? document.body.innerText : ''", arguments: [:], in: frame.info, contentWorld: .page)
            texts.append(text as? String ?? "")
        }
        #expect(texts.contains { $0.contains("inside page") }, "a frame inside the root did not load: \(texts)")
        #expect(!texts.contains { $0.contains("secret") }, "a frame outside the root loaded: \(texts)")
        let widths = try await webView.evaluateJavaScript(
            "[document.getElementById('outside').naturalWidth, document.getElementById('inside').naturalWidth]"
        ) as? [Int]
        #expect(widths?.first == 0, "an image outside the root loaded")
        #expect(widths?.last == 8, "an image inside the root did not load")
    }

    static func compile(_ rules: [[String: Any]]) async throws -> WKContentRuleList {
        // An empty list stands for no rules.
        let list = rules.isEmpty ? [["trigger": ["url-filter": "^cmux-never:"], "action": ["type": "block"]]] : rules
        let json = String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let compiled = try await store.compileContentRuleList(forIdentifier: "file-test", encodedContentRuleList: json)
        return try #require(compiled)
    }
}

/// When a session's domain policy or directories change, WebKit compiles
/// the new content rules asynchronously while its tabs' pages keep
/// running. Until the new list is on a tab, the tab carries the fail-closed
/// list, which blocks every load, so a live page cannot use the window to
/// load what the new rules forbid under the previous ones.
@MainActor
@Suite("Browser REPL fail-closed content rules", .serialized)
struct BrowserReplFailClosedRuleTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    @Test("A page under the fail-closed list loads no subresource, also one its previous rules allowed")
    func theFailClosedListBlocksEveryLoad() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#
        try Data(svg.utf8).write(to: URL(fileURLWithPath: scratch.root + "/dot.svg"))
        try Data("<p>page</p>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/page.html"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-fail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))

        let previous = try await BrowserReplFileContentRuleTests.compile(BrowserReplFileSandbox.contentRules(roots: [scratch.root]))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(previous)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = FileLoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(URL(fileURLWithPath: scratch.root + "/page.html"), allowingReadAccessTo: URL(fileURLWithPath: scratch.root))
        await waiter.wait()

        let loadImage = """
            const img = document.createElement("img");
            img.src = "dot.svg?" + Math.random();
            document.body.append(img);
            await new Promise((done) => { img.onload = done; img.onerror = done; });
            return img.naturalWidth;
            """
        let before = try await webView.callAsyncJavaScript(loadImage, arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect(before == 8, "the previous rules did not allow the image")

        let failClosed = try await BrowserReplContentRuleLists.failClosedList(in: store)
        configuration.userContentController.remove(previous)
        configuration.userContentController.add(failClosed)
        let during = try await webView.callAsyncJavaScript(loadImage, arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect(during == 0, "a load ran under the previous rules while the new ones compiled")
    }
}
