import Foundation
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

    @Test func preambleReportsChromeIdentity() {
        #expect(ChromeExtensionCompatibility.chromeUserAgent.contains(" Chrome/\(ChromeExtensionPackage.reportedChromeVersion) "))
        #expect(ChromeExtensionCompatibility.preambleSource.contains("ExecutionWorld"))
    }
}
