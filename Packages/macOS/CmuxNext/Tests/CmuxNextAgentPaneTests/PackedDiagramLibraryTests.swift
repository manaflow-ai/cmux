@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// The app stores Mermaid, Ondine and Vega packed (CMUX-570: scripts/cmux-next/pack-markdown-libraries.py,
/// the cmux-next target's "Pack markdown-viewer libraries" phase) and unpacks each into its caches on first
/// use (``PackedResource``). Packed by the build's own script, a diagram and a chart still draw from what
/// `__lib/` serves: cold (unpacked from the `.xz`) and warm (read from the cache).
@MainActor
struct PackedDiagramLibraryTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let libraries = repoRoot.appending(path: "Resources", directoryHint: .isDirectory)
        .appending(path: "markdown-viewer", directoryHint: .isDirectory)
    /// What these tests read: a read of the CI target graph.
    static let libraryReads = "Resources/markdown-viewer/*.min.js"
    static let packScript = repoRoot.appending(path: "scripts/cmux-next/pack-markdown-libraries.py")
    static let packed = ["mermaid.min.js", "ondine.min.js", "vega.min.js", "vega-lite.min.js", "vega-embed.min.js"]

    /// A copy of the repository's libraries packed by the build's script, and an empty cache beside it.
    private static func packedFolder() throws -> (folder: URL, cache: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("packed-libs-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appending(path: "markdown-viewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in packed {
            try FileManager.default.copyItem(at: libraries.appending(path: name), to: folder.appending(path: name))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", packScript.path, folder.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        for name in packed {
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: name).path), "\(name) is still raw")
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name + ".xz").path), "\(name).xz was not written")
        }
        return (folder, base.appending(path: "cache", directoryHint: .isDirectory))
    }

    /// The library `name` as `__lib/` serves it from the packed folder.
    private static func library(_ name: String, in folder: URL, cache: URL) async throws -> String {
        let data = try #require(await MarkdownPageResource.library(name, in: folder, packed: PackedResource(cache: cache)), "\(name)")
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func unpacksToTheSameBytesThenReadsFromTheCache() async throws {
        let (folder, cache) = try Self.packedFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let resource = PackedResource(cache: cache)
        for name in Self.packed {
            let original = try Data(contentsOf: Self.libraries.appending(path: name))
            #expect(resource.exists(folder.appending(path: name)))
            #expect(resource.data(folder.appending(path: name)) == original, "\(name): cold")
        }
        let kept = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        #expect(kept.count == Self.packed.count)
        // Warm: the kept copy answers, not the packed one (a marker written over it comes back).
        let mermaid = try #require(kept.first { $0.lastPathComponent.hasPrefix("mermaid.min.js-") })
        try Data("kept".utf8).write(to: mermaid)
        #expect(resource.data(folder.appending(path: "mermaid.min.js")) == Data("kept".utf8))
        #expect(resource.data(folder.appending(path: "no-such.js")) == nil)
        #expect(!resource.exists(folder.appending(path: "no-such.js")))
    }

    /// Draws a Mermaid diagram (with Mermaid and with Ondine) and a Vega-Lite chart in WebKit from the
    /// libraries `__lib/` serves out of the packed folder.
    private static func draw(folder: URL, cache: URL) async throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loads = PackedLoadWaiter()
        view.navigationDelegate = loads
        try await loads.load { view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil) }
        for name in ["mermaid.js", "ondine.js", "vega.js"] {
            let code = try await library(name, in: folder, cache: cache)
            _ = try await view.callAsyncJavaScript("(0, eval)(code); return true", arguments: ["code": code], in: nil, contentWorld: .page)
        }
        let mermaid = try await view.callAsyncJavaScript("""
            mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });
            return (await mermaid.render("packed-mermaid", "graph TD\\nPacked-->Drawn")).svg;
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(mermaid?.hasPrefix("<svg") == true, "\(mermaid?.prefix(200) ?? "nil")")
        #expect(mermaid?.contains("Packed") == true)
        let ondine = try await view.callAsyncJavaScript("""
            return ondine.create({ modules: { all: ondine.wasm } }).render("graph TD\\nPacked-->Drawn").svg;
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(ondine?.hasPrefix("<svg") == true, "\(ondine?.prefix(200) ?? "nil")")
        #expect(ondine?.contains("Drawn") == true)
        let vega = try await view.callAsyncJavaScript("""
            const spec = vegaLite.compile({
              data: { values: [{ a: "packed", b: 3 }, { a: "drawn", b: 5 }] },
              mark: "bar", encoding: { x: { field: "a", type: "nominal" }, y: { field: "b", type: "quantitative" } },
            }).spec;
            return await new vega.View(vega.parse(spec), { renderer: "none" }).toSVG();
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(vega?.hasPrefix("<svg") == true, "\(vega?.prefix(200) ?? "nil")")
        #expect(vega?.contains("mark-rect") == true)
        view.navigationDelegate = nil
    }

    @Test(.timeLimit(.minutes(2))) func aDiagramAndAChartDrawFromThePackedLibrariesColdThenWarm() async throws {
        let (folder, cache) = try Self.packedFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: cache.path), "the cache starts empty")
        try await Self.draw(folder: folder, cache: cache)
        let kept = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(kept.count == 4, "\(kept)") // mermaid, ondine, vega, vega-lite
        try await Self.draw(folder: folder, cache: cache)
    }
}

/// Resumes once the test's document finished loading, throws when it failed.
@MainActor
private final class PackedLoadWaiter: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Void, any Error>?

    func load(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            finished = continuation
            start()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
