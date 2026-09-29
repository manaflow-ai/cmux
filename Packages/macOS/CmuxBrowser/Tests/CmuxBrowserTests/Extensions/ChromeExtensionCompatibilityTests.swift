import Foundation
import JavaScriptCore
import Testing

@testable import CmuxBrowser

@Suite struct ChromeExtensionCompatibilityTests {
    private func makeExtension(background: [String: Any], pages: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-compat-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("popup"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "T", "version": "1", "background": background]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        for (path, html) in pages { try Data(html.utf8).write(to: root.appendingPathComponent(path)) }
        return root
    }

    private func manifest(_ root: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    @Test func prefixesClassicServiceWorkerIdempotently() throws {
        let root = try makeExtension(background: ["service_worker": "background.js"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("self.x = 1;\n".utf8).write(to: root.appendingPathComponent("background.js"))
        try ChromeExtensionCompatibility.install(into: root)
        try ChromeExtensionCompatibility.install(into: root)
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "background.js")
        let source = try String(contentsOf: root.appendingPathComponent("background.js"), encoding: .utf8)
        #expect(source.hasPrefix(ChromeExtensionCompatibility.beginMarker))
        #expect(source.hasSuffix(ChromeExtensionCompatibility.endMarker + "\nself.x = 1;\n"))
        #expect(source.components(separatedBy: ChromeExtensionCompatibility.beginMarker).count == 2)
    }

    /// A module worker keeps its name, so WebKit serves it as JavaScript,
    /// and imports the preamble first.
    @Test func prefixesModuleServiceWorkerWithImport() throws {
        let root = try makeExtension(background: ["service_worker": "bg/sw.js", "type": "module"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bg"), withIntermediateDirectories: true)
        try Data("import './a.js';\n".utf8).write(to: root.appendingPathComponent("bg/sw.js"))
        try ChromeExtensionCompatibility.install(into: root)
        try ChromeExtensionCompatibility.install(into: root)
        let source = try String(contentsOf: root.appendingPathComponent("bg/sw.js"), encoding: .utf8)
        #expect(source == "import \"/cmux-compat.js\";\nimport './a.js';\n")
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "bg/sw.js")
    }

    /// Earlier builds pointed the manifest at a wrapper; that is undone.
    @Test func migratesEarlierWrapperLayout() throws {
        let root = try makeExtension(background: ["service_worker": "cmux-compat-worker.mjs", "type": "module"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("export {};\n".utf8).write(to: root.appendingPathComponent("sw.js"))
        try Data("{\"serviceWorker\":\"sw.js\",\"isModule\":true}".utf8).write(to: root.appendingPathComponent(".cmux-compat.json"))
        try Data("import x;".utf8).write(to: root.appendingPathComponent("cmux-compat-worker.mjs"))
        try ChromeExtensionCompatibility.install(into: root)
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "sw.js")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-compat-worker.mjs").path))
        let source = try String(contentsOf: root.appendingPathComponent("sw.js"), encoding: .utf8)
        #expect(source == "import \"/cmux-compat.js\";\nexport {};\n")
    }

    @Test func prependsPreambleToLegacyBackgroundScripts() throws {
        let root = try makeExtension(background: ["scripts": ["a.js", "b.js"]])
        defer { try? FileManager.default.removeItem(at: root) }
        try ChromeExtensionCompatibility.install(into: root)
        try ChromeExtensionCompatibility.install(into: root)
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["scripts"] as? [String] == ["cmux-compat.js", "a.js", "b.js"])
    }

    @Test func injectsPreambleFirstInEveryPageOnce() throws {
        let root = try makeExtension(
            background: ["service_worker": "bg.js"],
            pages: ["popup/index.html": "<!doctype html><html><head><script src=\"app.js\"></script></head></html>"]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try ChromeExtensionCompatibility.install(into: root)
        try ChromeExtensionCompatibility.install(into: root)
        let html = try String(contentsOf: root.appendingPathComponent("popup/index.html"), encoding: .utf8)
        #expect(html == "<!doctype html><html><head><script src=\"/cmux-compat.js\"></script><script src=\"app.js\"></script></head></html>")
    }

    @Test func refusesTraversalInWorkerPath() throws {
        let root = try makeExtension(background: ["service_worker": "../../evil.js"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ChromeExtensionCompatibility.install(into: root)
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "../../evil.js")
    }

    /// Runs the preamble against a `chrome` object shaped like WebKit's:
    /// runtime, storage (local only), and a partial webNavigation.
    private func evaluateWithWebKitShapedChrome(_ probe: String) throws -> JSValue {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("""
            var globalThis = this;
            function event() { return { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } }; }
            var chrome = { runtime: {}, storage: { local: {} }, webNavigation: { onCommitted: event() } };
            """)
        context.evaluateScript(ChromeExtensionCompatibility.preambleSource)
        #expect(exception == nil, "\(exception ?? "")")
        return try #require(context.evaluateScript(probe))
    }

    @Test func missingNamespacesExistSoStartupCodeKeepsRunning() throws {
        // 1Password's worker reads these during startup; any TypeError stops it.
        let result = try evaluateWithWebKitShapedChrome("""
            chrome.notifications.onClicked.addListener(function () {});
            chrome.downloads.onChanged.addListener(function () {});
            chrome.idle.onStateChanged.addListener(function () {});
            chrome.webRequest.onAuthRequired.addListener(function () {}, { urls: ["<all_urls>"] }, ["blocking"]);
            chrome.webNavigation.onCreatedNavigationTarget.addListener(function () {});
            chrome.storage.managed.onChanged.addListener(function () {});
            [typeof chrome.privacy.services.passwordSavingEnabled.get,
             chrome.webNavigation.onCommitted.hasListener(function () {}) === false,
             chrome.idle.IdleState.LOCKED].join(",")
            """)
        #expect(result.toString() == "function,true,locked")
    }

    @Test func standInsAnswerEmptyAndRefuseActions() throws {
        let result = try evaluateWithWebKitShapedChrome("""
            var out = [];
            chrome.idle.queryState(60, function (state) { out.push(state); });
            chrome.storage.managed.get(null, function (items) { out.push(JSON.stringify(items)); });
            chrome.privacy.services.passwordSavingEnabled.get({}, function (d) { out.push(d.levelOfControl); });
            chrome.notifications.create({}, function () { out.push(chrome.runtime.lastError && chrome.runtime.lastError.message); });
            out.push(chrome.runtime.lastError === undefined);
            out.join("|")
            """)
        #expect(result.toString() == "active|{}|not_controllable|chrome.notifications.create is not available in cmux|true")
    }

    @Test func prefixesIsolatedContentScriptsOnlyAndIdempotently() throws {
        // JSON Formatter's shape: one isolated entry, one MAIN-world entry, no background.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-compat-cs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [
                ["matches": ["<all_urls>"], "js": ["content.js"]],
                ["matches": ["<all_urls>"], "js": ["page.js"], "world": "MAIN"],
            ],
        ]
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        try ChromeExtensionCompatibility.install(into: root)
        let first = try Data(contentsOf: manifestURL)
        try ChromeExtensionCompatibility.install(into: root)
        #expect(try Data(contentsOf: manifestURL) == first)

        let written = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        let scripts = try #require(written["content_scripts"] as? [[String: Any]])
        #expect(scripts[0]["js"] as? [String] == [ChromeExtensionCompatibility.contentPreambleFile, "content.js"])
        #expect(scripts[1]["js"] as? [String] == ["page.js"])
        #expect(written["background"] == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(ChromeExtensionCompatibility.contentPreambleFile).path))
    }

    @Test func preambleReportsChromeIdentity() {
        #expect(ChromeExtensionCompatibility.chromeUserAgent.contains(" Chrome/\(ChromeExtensionPackage.reportedChromeVersion) "))
        #expect(ChromeExtensionCompatibility.preambleSource.contains("ExecutionWorld"))
    }
}
