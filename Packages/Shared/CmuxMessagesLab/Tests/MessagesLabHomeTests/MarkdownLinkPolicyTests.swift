import Foundation
import Testing
@testable import MessagesLabHome

/// Markdown links (security): only http, https and mailto become links. Every
/// other scheme, an obfuscated scheme and a relative URL stay plain text, and
/// the engine never loads a URL (an image is a link or text, never fetched).
@Suite(.serialized) struct MarkdownLinkPolicyTests {
    static let refused = [
        "javascript:alert(1)", "JaVaScRiPt:alert(1)", "java\tscript:alert(1)", " javascript:alert(1)",
        "&#106;avascript:alert(1)", "%6Aavascript:alert(1)", "file:///etc/passwd", "data:text/html,x",
        "vbscript:x", "ssh://host", "x-apple-reminder://x", "/relative/path", "relative/path", "#anchor", "//host/path",
    ]
    static let allowed = ["https://cmux.com/a", "http://cmux.com", "mailto:a@cmux.com", "HTTPS://cmux.com"]

    private func links(_ source: String) -> [String] { MDInlineParser.parse(source).spans.compactMap(\.link) }

    @Test(arguments: refused)
    func anInlineLinkWithARefusedDestinationIsPlainText(_ dest: String) {
        #expect(links("see [this](\(dest)) now").isEmpty, "no link for \(dest.debugDescription)")
    }

    @Test(arguments: refused)
    func anImageWithARefusedDestinationIsPlainText(_ dest: String) {
        #expect(links("![chart](\(dest))").isEmpty, "no link for \(dest.debugDescription)")
    }

    @Test func angleAutolinksFollowTheSameRule() {
        #expect(links("<javascript:alert(1)>").isEmpty)
        #expect(links("<file:///etc/passwd>").isEmpty)
        #expect(links("<https://cmux.com>") == ["https://cmux.com"])
        #expect(links("<a@cmux.com>") == ["mailto:a@cmux.com"])
    }

    @Test(arguments: allowed)
    func httpHttpsAndMailtoStayLinks(_ dest: String) {
        #expect(links("see [this](\(dest)) now") == [dest])
    }

    @Test func extendedAutolinksAndEmailsStayLinks() {
        #expect(links("go to www.cmux.com now") == ["http://www.cmux.com"])
        #expect(links("write a@cmux.com") == ["mailto:a@cmux.com"])
    }

    @Test func anImageIsNeverLoaded() {
        NoNetwork.reset()
        URLProtocol.registerClass(NoNetwork.self)
        defer { URLProtocol.unregisterClass(NoNetwork.self) }
        let source = "Look: ![chart](https://example.com/chart.png) and ![x](http://10.0.0.1/a.png)"
        let text = MDInlineParser.parse(source)
        #expect(text.string.contains("chart"), "the alt text shows")
        #expect(!text.string.contains("https://example.com/chart.png") || text.spans.contains { $0.link != nil },
                "the destination shows only as a link")
        _ = Markdown.layout(source, message: nil, width: 628)
        #expect(NoNetwork.requests == 0, "no URL was requested")
    }
}

/// Counts every request the URL loading system starts in the process, and fails it.
final class NoNetwork: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
