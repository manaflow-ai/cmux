@testable import CmuxNextPages
import Foundation
import Testing

/// The one per-page CSP (decided 2026-10-04): strict by default; only first-party pages widen it,
/// and only with connect/frame sources and the 'wasm-unsafe-eval' keyword.
@Suite struct PageCSPTests {
    static let strict =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:"

    @Test func everyPageStartsStrict() {
        #expect(PageCSP.strict.header == Self.strict)
        #expect(PageSchemeHandler.contentSecurityPolicy == Self.strict)
    }

    @Test func aFirstPartyPageAddsConnectFrameAndWasm() {
        let agent = PageDescriptor(id: "cmux.agent", resource: "agent", namespaces: ["cmux.agent."],
                                   csp: PageCSP(connect: ["ws://127.0.0.1:*"], frame: ["http://127.0.0.1:*"], script: ["'wasm-unsafe-eval'"]))
        #expect(agent.csp.header == "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data:; font-src 'self' data:; connect-src ws://127.0.0.1:*; frame-src http://127.0.0.1:*")
    }

    /// A page that ships its script as files turns inline script off; the rest stays as it was.
    @Test func aPageCanTurnInlineScriptOff() {
        let files = PageCSP(connect: ["ws://127.0.0.1:*"], script: ["'wasm-unsafe-eval'"], inlineScript: false)
        #expect(files.header == "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data:; font-src 'self' data:; connect-src ws://127.0.0.1:*")
    }

    @Test func anAppPageOrAReservedUnknownIDCannotWidenIt() throws {
        let wide = PageCSP(connect: ["https://evil.example"], script: ["'wasm-unsafe-eval'"])
        #expect(PageDescriptor(id: "com.acme.diff", resource: "d", namespaces: [], csp: wide).csp == .strict)
        #expect(PageDescriptor(id: "cmux.agentx", resource: "x", namespaces: [], csp: wide).csp == .strict)
        #expect(try PageDescriptor.appPage(id: "com.acme.diff", resource: "d", namespaces: []).csp == .strict)
    }

    @Test func unsafeSourcesAndKeywordsAreDropped() {
        let csp = PageCSP(connect: ["ws://a; script-src *", "https://x, https://y", "", "wss://ok"],
                          frame: ["http://a b"], script: ["'unsafe-eval'", "'wasm-unsafe-eval'"])
        #expect(csp.header.hasSuffix("connect-src wss://ok"))
        #expect(!csp.header.contains("'unsafe-eval'"))
        #expect(!csp.header.contains("frame-src"))
    }

    @Test func modulesAreJavaScriptAndAPageMayNameItsEntry() {
        #expect(PageSchemeHandler.mimeType(forExtension: "mjs") == "text/javascript")
        #expect(PageSchemeHandler.mimeType(forExtension: "js") == "text/javascript")
        #expect(PageSchemeHandler.mimeType(forExtension: "wasm") == "application/wasm")
        let diff = PageDescriptor(id: "cmux.diff", resource: "webviews-app", namespaces: [], entry: "diff.html")
        let root = URL(fileURLWithPath: "/tmp/webviews-app")
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.diff/")!, page: diff, root: root)?.lastPathComponent == "diff.html")
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.diff/chunks/diffSurface.mjs")!, page: diff, root: root)?.path
            == "/tmp/webviews-app/chunks/diffSurface.mjs")
        #expect(PageDescriptor(id: "cmux.diff", resource: "x", namespaces: [], entry: "../evil.html").entry == "index.html")
    }

    /// The diff page adds exactly its own origin and WebAssembly; every other shipped page keeps
    /// the strict default (diff-host.md S1).
    @Test func theDiffPageAddsOnlyItsOwnOriginAndWebAssembly() throws {
        #expect(PageDescriptor.diff.csp.header
            == "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data:; font-src 'self' data:; connect-src cmux-page://cmux.diff")
        #expect(PageDescriptor.diff.csp.connect == [PageDescriptor.diff.origin])
        for page in [PageDescriptor.markdown, .history, .cloud] {
            #expect(page.csp == .strict, "\(page.id)")
        }
    }

    @MainActor @Test func everyDiffResponseCarriesTheDiffCSP() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-csp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appending(path: PageDescriptor.diff.entry))
        let handler = PageSchemeHandler(page: .diff, root: root)
        for raw in ["cmux-page://cmux.diff/", "cmux-page://cmux.diff/__patch/missing"] {
            let url = try #require(URL(string: raw))
            let reply = await handler.reply(to: url)
            #expect(reply?.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageDescriptor.diff.csp.header, "\(raw)")
        }
    }
}
