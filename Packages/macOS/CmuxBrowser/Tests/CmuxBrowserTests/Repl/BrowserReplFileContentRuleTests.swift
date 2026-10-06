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

    /// r23 native#1: the root exception let a local page inside the root
    /// load a file `secrets.load` protects as a subresource (an image, a
    /// script, a fetch), by its own name, after a rename, through a link
    /// or spelled another way. The navigation checks judge the file by
    /// its identity; the content rules judge only the URL.
    @Test("A file secrets.load protects does not load as a subresource under any name")
    func aProtectedSecretsFileDoesNotLoadAsASubresource() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#
        try manager.createDirectory(atPath: scratch.root + "/sub", withIntermediateDirectories: true)
        try Data(svg.utf8).write(to: URL(fileURLWithPath: scratch.root + "/secret.svg"))
        try Data("window.leaked = 'secret bytes';".utf8).write(to: URL(fileURLWithPath: scratch.root + "/loaded.js"))
        for path in ["/secret.svg", "/loaded.js"] {
            let identity = try #require(BrowserReplFileIdentity(path: scratch.root + path))
            try BrowserReplFileSandbox.pathChangeLock.withLock { try BrowserReplSecretSources.shared.protect(identity) }
        }
        // After the load: a rename, and a link to the protected file.
        try manager.moveItem(atPath: scratch.root + "/loaded.js", toPath: scratch.root + "/sub/moved.js")
        try manager.createSymbolicLink(atPath: scratch.root + "/link.svg", withDestinationPath: scratch.root + "/secret.svg")
        let caseInsensitive = manager.fileExists(atPath: scratch.root + "/SECRET.svg")
        try Data("""
            <p>main</p>
            <img id=name src="secret.svg"><img id=link src="link.svg"><img id=spelled src="SECRET.svg">
            <img id=dotted src="sub/../secret.svg">
            <script src="sub/moved.js"></script>
            """.utf8).write(to: URL(fileURLWithPath: scratch.root + "/page.html"))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(try await Self.compile(BrowserReplFileSandbox.contentRules(roots: [scratch.root])))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = FileLoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(URL(fileURLWithPath: scratch.root + "/page.html"), allowingReadAccessTo: URL(fileURLWithPath: scratch.root))
        await waiter.wait()

        let widths = try await webView.evaluateJavaScript(
            "['name', 'link', 'spelled', 'dotted'].map((id) => document.getElementById(id).naturalWidth)"
        ) as? [Int]
        #expect(widths?[0] == 0, "the protected file loaded as an image by its own name")
        #expect(widths?[1] == 0, "the protected file loaded as an image through a link to it")
        if caseInsensitive { #expect(widths?[2] == 0, "the protected file loaded as an image spelled in other case") }
        #expect(widths?[3] == 0, "the protected file loaded as an image through a `..` spelling")
        let leaked = try await webView.evaluateJavaScript("String(window.leaked)") as? String
        #expect(leaked != "secret bytes", "a protected file, renamed after the load, ran as a script")
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

/// Which roots lose their `file:` subresources while files are protected
/// (``BrowserReplSecretSources/mayHoldFile(under:)``): judged by directory
/// identity, failing closed where a name cannot be found.
@Suite("Browser REPL roots that may hold a protected file")
struct BrowserReplSecretSourceRootTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    @Test("A root holds a protected file below it or another hard link of it; another root does not")
    func rootsThatHoldAProtectedFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let manager = FileManager.default
        let sources = BrowserReplSecretSources()
        let other = scratch.base + "/other"
        try manager.createDirectory(atPath: scratch.root + "/deep/er", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: other, withIntermediateDirectories: true)
        try Data("A=1".utf8).write(to: URL(fileURLWithPath: scratch.root + "/deep/er/.env"))
        #expect(!sources.mayHoldFile(under: [scratch.root]), "no file is protected")

        try sources.protect(try #require(BrowserReplFileIdentity(path: scratch.root + "/deep/er/.env")))
        #expect(sources.mayHoldFile(under: [scratch.root]))
        #expect(sources.mayHoldFile(under: [scratch.root + "/deep"]))
        #expect(!sources.mayHoldFile(under: [other]), "a root that holds no name of the file")
        #expect(!sources.mayHoldFile(under: [scratch.outside, other]))

        // Another hard link: only one name can be found, so every root on
        // the volume may hold it.
        try manager.linkItem(atPath: scratch.root + "/deep/er/.env", toPath: scratch.root + "/hard.env")
        #expect(sources.mayHoldFile(under: [other]))
        try manager.removeItem(atPath: scratch.root + "/hard.env")

        // Moved out of the root: the root no longer holds it, the new one does.
        try manager.moveItem(atPath: scratch.root + "/deep/er/.env", toPath: other + "/.env")
        #expect(!sources.mayHoldFile(under: [scratch.root]))
        #expect(sources.mayHoldFile(under: [other]))

        // Removed: nothing holds it.
        try manager.removeItem(atPath: other + "/.env")
        #expect(!sources.mayHoldFile(under: [other]))
    }

    @Test("Rules for a root without a protected file still load its subresources; with one, none")
    func rulesFollowTheRoots() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sources = BrowserReplSecretSources()
        try Data("A=1".utf8).write(to: URL(fileURLWithPath: scratch.root + "/.env"))
        try sources.protect(try #require(BrowserReplFileIdentity(path: scratch.root + "/.env")))
        let allowsSubresources = { (roots: [String]) in
            BrowserReplFileSandbox.contentRules(roots: roots, secretSources: sources).contains { rule in
                let trigger = rule["trigger"] as? [String: Any]
                let action = rule["action"] as? [String: Any]
                return action?["type"] as? String == "ignore-previous-rules" && trigger?["load-context"] == nil
            }
        }
        #expect(!allowsSubresources([scratch.root]))
        #expect(allowsSubresources([scratch.outside]))
    }
}
