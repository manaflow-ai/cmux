import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import JavaScriptCore
import Testing

/// Saved extension site styles reached a Chromium page only after it committed: the installer ran
/// from Swift once the commit was heard, a round trip after parsing began, so on a cached visit the
/// style landed after DOMContentLoaded and the load event (GUI proof: ~29 ms after navigation start,
/// load ~16.5 ms) and clutter could paint first. Each browser now holds one document-start script
/// for the snapshot (`Page.addScriptToEvaluateOnNewDocument`, `CEFSiteStyleBridge`), replaced new
/// first then old out when the snapshot changes, and the commit-time installers stand down while
/// it is in.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFSiteStyleStartTests {
    @Test func theScriptRunsOnlyItsOwnOriginsInstallersInTheTopDocument() throws {
        let script = BrowserSiteControl.documentStartScript([
            "https://news.test": ["ran.push('news-1')", "ran.push('news-2')"],
            "http://127.0.0.1:18431": ["ran.push('local')"],
            "https://empty.test": [],
        ])
        #expect(BrowserSiteControl.documentStartScript([:]).isEmpty)
        #expect(BrowserSiteControl.documentStartScript(["https://empty.test": []]).isEmpty)
        #expect(script == BrowserSiteControl.documentStartScript([
            "http://127.0.0.1:18431": ["ran.push('local')"],
            "https://news.test": ["ran.push('news-1')", "ran.push('news-2')"],
        ]), "the same snapshot gives the same script, so an unchanged snapshot replaces nothing")

        func run(origin: String, top: Bool = true) throws -> [String] {
            let context = try #require(JSContext())
            var thrown: String?
            context.exceptionHandler = { _, value in thrown = value?.toString() }
            context.evaluateScript("var ran = []; var window = this; window.top = \(top ? "window" : "{}"); var location = { origin: '\(origin)' };")
            context.evaluateScript(script)
            #expect(thrown == nil, "\(thrown ?? "")")
            return context.objectForKeyedSubscript("ran").toArray().compactMap { $0 as? String }
        }
        #expect(try run(origin: "https://news.test") == ["news-1", "news-2"])
        #expect(try run(origin: "http://127.0.0.1:18431") == ["local"])
        #expect(try run(origin: "https://other.test").isEmpty)
        #expect(try run(origin: "constructor").isEmpty, "an origin is looked up as an own key only")
        #expect(try run(origin: "https://news.test", top: false).isEmpty, "a frame runs none, as the commit path styles the main frame only")
    }

    @Test func eachBrowserHoldsTheSnapshotsScriptFromDocumentStart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-site-style-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        StyleSpyShim.reset()
        let runtime = CEFRuntime(shim: try StyleSpyShim.library(), storage: CEFProfileStorage(root: root))
        StyleSpyShim.runtimes.append(runtime)
        #expect(!runtime.forkFeatures.rendererPaths, "the DevTools path: the spy reports fork API 0")
        let first = BrowserSiteControl.documentStartScript(["https://news.test": ["/* hide ads */"]])
        runtime.stores.documentStartScript = first

        // A browser made with a snapshot in place registers it as it attaches.
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        try #require(tab.browserID == 7)
        await StyleSpyShim.answering(runtime) { tab.agentRelay.siteStylesCoverNewDocuments }
        #expect(StyleSpyShim.styleCalls == [.add(first)])
        #expect(tab.agentRelay.siteStylesCoverNewDocuments)

        // A commit asks for no installer then: the document already has the style.
        var commitAsked: [String] = []
        runtime.stores.documentCommitScripts = { origin in
            commitAsked.append(origin)
            return []
        }
        tab.pageInfoDocumentCommitted(URL(string: "https://news.test/story"))
        #expect(commitAsked.isEmpty, "the commit-time installers must stand down while the script is in")

        // A new snapshot: until its script is in, a commit installs as before; then the new script
        // goes in before the old one comes out.
        StyleSpyShim.styleCalls = []
        let second = BrowserSiteControl.documentStartScript(["https://news.test": ["/* hide ads */", "/* unstick header */"]])
        runtime.stores.documentStartScript = second
        #expect(!tab.agentRelay.siteStylesCoverNewDocuments)
        tab.pageInfoDocumentCommitted(URL(string: "https://news.test/next"))
        #expect(commitAsked == ["https://news.test"])
        runtime.syncSiteStyles()
        await StyleSpyShim.answering(runtime) { tab.agentRelay.siteStylesCoverNewDocuments }
        let firstID = try #require(StyleSpyShim.identifier(of: first))
        #expect(StyleSpyShim.styleCalls == [.add(second), .remove(firstID)])

        // No styles left: the script comes out and nothing replaces it.
        StyleSpyShim.styleCalls = []
        runtime.stores.documentStartScript = ""
        runtime.syncSiteStyles()
        let secondID = try #require(StyleSpyShim.identifier(of: second))
        await StyleSpyShim.answering(runtime) { StyleSpyShim.styleCalls.count == 1 }
        await StyleSpyShim.answering(runtime) { false }
        #expect(StyleSpyShim.styleCalls == [.remove(secondID)])
        #expect(tab.agentRelay.siteStylesCoverNewDocuments)
        withExtendedLifetime(tab) {}
    }

    @Test func theRendererPathsKeepTheCommitTimeInstallers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-site-style-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        StyleSpyShim.reset()
        StyleSpyShim.forkAPI = CEFForkFeatures.rendererPathsForkAPI
        let runtime = CEFRuntime(shim: try StyleSpyShim.library(), storage: CEFProfileStorage(root: root))
        StyleSpyShim.runtimes.append(runtime)
        #expect(runtime.forkFeatures.rendererPaths)
        runtime.stores.documentStartScript = BrowserSiteControl.documentStartScript(["https://news.test": ["/* hide ads */"]])
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 8, request: request, window: 1))
        runtime.syncSiteStyles()
        #expect(StyleSpyShim.styleCalls.isEmpty, "a renderer-path tab opens no DevTools session for styles")
        #expect(!tab.agentRelay.siteStylesCoverNewDocuments, "so its commits keep installing them")
        withExtendedLifetime(tab) {}
    }
}

/// Stand-in shim: records every DevTools call with its parameters and answers them when asked, a
/// `Page.addScriptToEvaluateOnNewDocument` with a fresh identifier; every other function does nothing.
private nonisolated enum StyleSpyShim {
    struct Sent { let id: Int32; let method: String; let params: [String: Any] }
    enum StyleCall: Equatable {
        case add(String)
        case remove(String)
    }
    nonisolated(unsafe) static var forkAPI: Int32 = 0 // test-only, main thread (the suite is serialized)
    nonisolated(unsafe) static var sent: [Sent] = []
    nonisolated(unsafe) static var unanswered: [Sent] = []
    nonisolated(unsafe) static var nextID: Int32 = 1
    /// The site-style script calls (`cmux` world adds and every remove), in order.
    nonisolated(unsafe) static var styleCalls: [StyleCall] = []
    /// Identifier answered for each added source.
    nonisolated(unsafe) static var identifiers: [String: String] = [:]
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    static func reset() {
        forkAPI = 0
        sent = []
        unanswered = []
        nextID = 1
        styleCalls = []
        identifiers = [:]
    }

    static func identifier(of source: String) -> String? { identifiers[source] }

    /// Answers every DevTools call sent (as Chromium's DEVTOOLS_RESULT would) until `condition`.
    @MainActor static func answering(_ runtime: CEFRuntime, until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            let pending = unanswered
            unanswered = []
            for call in pending {
                var json = "{}"
                if call.method == "Page.addScriptToEvaluateOnNewDocument" {
                    let identifier = "script-\(call.id)"
                    if let source = call.params["source"] as? String { identifiers[source] = identifier }
                    json = "{\"identifier\":\"\(identifier)\"}"
                }
                runtime.handle(.devToolsResult(browser: 7, messageID: call.id, success: true, json: json))
            }
            await Task.yield()
        }
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { StyleSpyShim.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, params in
            let name = method.map { String(cString: $0) } ?? ""
            let json = params.map { String(cString: $0) } ?? "{}"
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            StyleSpyShim.nextID += 1
            let call = Sent(id: StyleSpyShim.nextID, method: name, params: object)
            StyleSpyShim.sent.append(call)
            StyleSpyShim.unanswered.append(call)
            if name == "Page.addScriptToEvaluateOnNewDocument", object["worldName"] as? String == CEFSiteStyleBridge.world,
               let source = object["source"] as? String {
                StyleSpyShim.styleCalls.append(.add(source))
            } else if name == "Page.removeScriptToEvaluateOnNewDocument", let identifier = object["identifier"] as? String {
                StyleSpyShim.styleCalls.append(.remove(identifier))
            }
            return StyleSpyShim.nextID
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
