import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser REPL runtime bundle")
struct BrowserReplRuntimeBundleTests {
    private func makeDirectory(files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-repl-bundle-\(UUID().uuidString)", isDirectory: true)
        for (name, contents) in files {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return directory
    }

    @Test("Scripts load in manifest order")
    func loadsInManifestOrder() throws {
        let directory = try makeDirectory(files: [
            "manifest.json": #"{ "repl": ["b.js", "vendor/a.js"], "agent": ["agent.js"] }"#,
            "vendor/a.js": "a",
            "b.js": "b",
            "agent.js": "agent",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try BrowserReplRuntimeBundle.load(from: directory)
        #expect(bundle.replScripts == [.init(name: "b.js", source: "b"), .init(name: "vendor/a.js", source: "a")])
        #expect(bundle.agentScripts == [.init(name: "agent.js", source: "agent")])
    }

    @Test("A missing manifest is an error")
    func missingManifest() throws {
        let directory = try makeDirectory(files: ["runtime-core.js": "x"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: BrowserReplRuntimeBundleError.manifestMissing(path: directory.appendingPathComponent("manifest.json").path)) {
            try BrowserReplRuntimeBundle.load(from: directory)
        }
    }

    @Test("A manifest that is not an object of two lists is an error")
    func invalidManifest() throws {
        let directory = try makeDirectory(files: ["manifest.json": #"["runtime-core.js"]"#])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: BrowserReplRuntimeBundleError.manifestInvalid(path: directory.appendingPathComponent("manifest.json").path)) {
            try BrowserReplRuntimeBundle.load(from: directory)
        }
    }

    @Test("A listed file that is missing, or outside the directory, is an error")
    func missingScript() throws {
        let directory = try makeDirectory(files: [
            "manifest.json": #"{ "repl": ["api.js"], "agent": ["../escape.js"] }"#,
            "api.js": "api",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: BrowserReplRuntimeBundleError.scriptMissing(
            name: "../escape.js",
            path: directory.appendingPathComponent("../escape.js").path
        )) {
            try BrowserReplRuntimeBundle.load(from: directory)
        }
    }
}
