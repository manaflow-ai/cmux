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

    @Test func wrapsClassicServiceWorkerIdempotently() throws {
        let root = try makeExtension(background: ["service_worker": "background.js"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ChromeExtensionCompatibility.install(into: root)
        try ChromeExtensionCompatibility.install(into: root)
        let background = try #require(try manifest(root)["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == ChromeExtensionCompatibility.workerWrapperFile)
        let wrapper = try String(contentsOf: root.appendingPathComponent(ChromeExtensionCompatibility.workerWrapperFile), encoding: .utf8)
        #expect(wrapper == "importScripts(\"/cmux-compat.js\", \"/background.js\");\n")
    }

    @Test func wrapsModuleServiceWorkerWithOrderedImports() throws {
        let root = try makeExtension(background: ["service_worker": "sw.js", "type": "module"])
        defer { try? FileManager.default.removeItem(at: root) }
        try ChromeExtensionCompatibility.install(into: root)
        let wrapper = try String(contentsOf: root.appendingPathComponent(ChromeExtensionCompatibility.moduleWorkerWrapperFile), encoding: .utf8)
        #expect(wrapper == "import \"/cmux-compat.js\";\nimport \"/sw.js\";\n")
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
