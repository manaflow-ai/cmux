@testable import CmuxNextAgentPane
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// A ```mermaid block in a chat on the shared page host (`cmux-page://cmux.agent`) draws (user,
/// Nov 20: "Couldn't draw this chart: ondine library failed to load" on the nightly). The chat's
/// diagram code (pages/markdown/diagrams.ts) loads Ondine and Mermaid as same-origin scripts from
/// `__lib/` beside the page; the pane's old host served them, the page host answered 404. Observed
/// in WebKit under the page's own CSP, with the app's bundled libraries and the user's chart.
@MainActor
struct AgentPageDiagramLibraryTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The bundled libraries' folder. Built from two names so the CI target graph records the files the
    /// tests read (``libraryReads``), not the whole folder: its regenerated web bundle is no input here.
    static let libraries = repoRoot.appending(path: "Resources", directoryHint: .isDirectory)
        .appending(path: "markdown-viewer", directoryHint: .isDirectory)
    /// What these tests read from ``libraries`` (Ondine, Mermaid, Vega): a read of the CI target graph.
    static let libraryReads = "Resources/markdown-viewer/*.min.js"

    /// The chart from the user's screenshot (webviews/test/fixtures, which the pane's own tests
    /// draw too): subgraphs, `<br/>` labels, quoted edge labels with braces, `:::` classes and `classDef` lines.
    static func chart() throws -> String {
        try String(contentsOf: repoRoot.appending(path: "webviews/test/fixtures/mermaid-front-door.mmd"), encoding: .utf8)
    }

    /// What diagrams.ts does (`DiagramLibraries.load`, then `renderOndine`): a script element for
    /// `__lib/<name>.js` resolved against the page, then Ondine's renderer over the source.
    static let probe = """
        window.draw = (source) => new Promise((resolve) => {
          const script = document.createElement("script");
          script.src = new URL("__lib/ondine.js", document.baseURI).href;
          script.onerror = () => resolve("error: ondine library failed to load");
          script.onload = () => {
            try {
              const renderer = globalThis.ondine.create({ modules: { all: globalThis.ondine.wasm } });
              resolve(renderer.render(source).svg);
            } catch (error) {
              resolve("error: " + (error && error.message ? error.message : String(error)));
            }
          };
          document.head.append(script);
        });
        """

    /// A page root holding a document whose only script is the probe (the page's CSP allows no inline script).
    private static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-page-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><meta charset=utf-8><script src=\"probe.js\"></script>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        try Data(probe.utf8).write(to: root.appendingPathComponent("probe.js"))
        return root
    }

    private static func resources() -> AgentPageResources {
        AgentPageResources(session: { nil }, allowed: { true }, libraries: libraries)
    }

    @Test(.timeLimit(.minutes(1))) func theUsersMermaidChartDrawsInTheChatPage() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        // The handler holds its source weakly (the page view owns it in the app): the test keeps it.
        let resources = Self.resources()
        let handler = PageSchemeHandler(page: .agent, root: root, dynamicSource: resources, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loads = LoadWaiter()
        view.navigationDelegate = loads
        let page = try #require(URL(string: "\(PageDescriptor.scheme)://\(PageDescriptor.agent.id)/index.html"))
        try await loads.load { view.load(URLRequest(url: page)) }

        let drawn = try await view.callAsyncJavaScript("return await draw(source)", arguments: ["source": try Self.chart()],
                                                       in: nil, contentWorld: .page) as? String
        let svg = try #require(drawn)
        #expect(svg.hasPrefix("<svg"), "\(svg.prefix(200))")
        #expect(svg.contains("ondine-flowchart"))
        // Labels Ondine keeps on one line (it wraps long node labels into several).
        #expect(svg.contains("Read path - the only front door"))
        #expect(svg.contains("log each decrypt"))
        view.navigationDelegate = nil
        withExtendedLifetime(resources) {}
    }

    @Test func thePageHostServesEveryChartLibraryAndNothingElse() async throws {
        let resources = Self.resources()
        for (name, head) in [("ondine.js", "/*! ondine"), ("mermaid.js", ""), ("vega.js", "")] {
            let url = try #require(URL(string: "cmux-page://cmux.agent/__lib/\(name)"))
            let request = try #require(PageSchemeHandler.dynamicRequest(for: url, page: .agent), "\(name) is not a dynamic path")
            // Chromium's path: the source's answer with only its range headers.
            let answer = await PageSchemeHandler.rangedResponse(to: request, range: nil, source: resources)
            #expect(answer.status == 200, "\(name)")
            #expect(answer.mimeType.hasPrefix("text/javascript"), "\(name): \(answer.mimeType)")
            #expect(answer.body.count > 100_000, "\(name)")
            #expect(String(decoding: answer.body.prefix(head.utf8.count), as: UTF8.self) == head, "\(name)")
        }
        for name in ["marked.min.js", "ondine.min.js", "shell.html", "..%2Fondine.js"] {
            let url = try #require(URL(string: "cmux-page://cmux.agent/__lib/\(name)"))
            guard let request = PageSchemeHandler.dynamicRequest(for: url, page: .agent) else { continue }
            #expect(await PageSchemeHandler.rangedResponse(to: request, range: nil, source: resources).status == 404, "\(name)")
        }
    }
}

/// Resumes once the test's document finished loading, throws when it failed.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
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
