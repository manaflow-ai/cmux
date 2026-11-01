@testable import CmuxNextApp
import Foundation
import Testing

/// The local live link (design section 4.1): the Markdown rendered to escaped HTML on the Mac, a
/// loopback server that serves only shared files under an unguessable token, and a Server-Sent
/// Events stream that says `reload` when the file changes on disk.
@MainActor @Suite(.serialized) struct MarkdownLiveShareTests {
    // MARK: Renderer

    @Test func blocksRenderAsHTML() {
        let html = MarkdownHTMLRenderer().body("""
        # Title

        Some *emphasis*, **strong**, `code` and a [link](https://cmux.dev).

        - one
        - two

        1. first
        2. second

        > quoted

        ```swift
        let x = 1
        ```

        | A | B |
        | - | - |
        | 1 | 2 |
        """)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<em>emphasis</em>"))
        #expect(html.contains("<strong>strong</strong>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<a href=\"https://cmux.dev\">link</a>"))
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>one</li>") || html.contains("<li><p>one</p></li>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>A</th>"))
        #expect(html.contains("<td>2</td>"))
    }

    @Test func rawHTMLAndScriptsAreShownAsText() {
        let html = MarkdownHTMLRenderer().body("""
        <script>alert(1)</script>

        Text with <img src=x onerror=alert(1)> and [bad](javascript:alert(1)).
        """)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("Text with"))
    }

    @Test func theDocumentCarriesAStrictPolicyAndTheReloadScript() {
        let page = MarkdownHTMLRenderer().document("# Hi\n", title: "a <b>.md", eventsPath: "/md/tok/a.md/events")
        #expect(page.contains("<title>a &lt;b&gt;.md</title>"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("EventSource(\"/md/tok/a.md/events\")"))
    }

    // MARK: Routes

    @Test(arguments: [
        ("/md/abc/notes.md", MarkdownLiveShareRoute.page(token: "abc")),
        ("/md/abc/notes.md/events", .events(token: "abc")),
        ("/md/abc/my%20notes.md", .page(token: "abc")),
    ])
    func sharedPathsRoute(path: String, expected: MarkdownLiveShareRoute) {
        #expect(MarkdownLiveShareRoute(path: path) == expected)
    }

    @Test(arguments: ["/", "/md", "/md/", "/md/abc", "/etc/passwd", "/md/abc/../x.md", "/md/a/b/c/d"])
    func otherPathsDoNotRoute(path: String) {
        #expect(MarkdownLiveShareRoute(path: path) == nil)
    }

    // MARK: Server

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    @Test func aSharedFileIsServedOnLoopbackAndOthersAreNot() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.md")
        try Data("# Shared notes\n".utf8).write(to: file)
        let server = MarkdownLiveShareServer()
        defer { server.stop() }
        let link = try await server.link(for: file)
        #expect(link.host == "127.0.0.1")
        #expect(link.path.hasPrefix("/md/"))
        #expect(link.lastPathComponent == "notes.md")
        // The same file keeps its link.
        #expect(try await server.link(for: file) == link)

        let (body, response) = try await URLSession.shared.data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        #expect(String(decoding: body, as: UTF8.self).contains("<h1>Shared notes</h1>"))

        var other = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        other.path = "/md/not-a-token/notes.md"
        let (_, missing) = try await URLSession.shared.data(from: other.url!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func aChangeOnDiskSendsReload() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "live.md")
        try Data("# One\n".utf8).write(to: file)
        let server = MarkdownLiveShareServer()
        defer { server.stop() }
        let link = try await server.link(for: file)
        let events = link.appending(path: "events")
        let (bytes, response) = try await URLSession.shared.bytes(from: events)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true)
        let reload = Task {
            for try await line in bytes.lines where line.hasPrefix("data:") {
                if line.contains("reload") { return true }
            }
            return false
        }
        // The server starts the file's watcher before it answers the headers, so the watcher is on.
        try Data("# Two\n".utf8).write(to: file)
        let got = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await reload.value }
            // test-deadline: a bound on the whole wait, not a settle; the watcher signals by sending `reload`.
            // Load-tolerant: the change hops to the main actor twice (the watcher's event, then the
            // read after its debounce), which a loaded runner held 5 s and longer (tip runs 2026-11-01).
            group.addTask { try await Task.sleep(for: .seconds(60)); reload.cancel(); return false }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(got)
    }
}
