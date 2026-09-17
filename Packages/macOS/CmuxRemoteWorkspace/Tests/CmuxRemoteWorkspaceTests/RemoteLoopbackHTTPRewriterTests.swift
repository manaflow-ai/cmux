import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

private let alias = RemoteLoopbackProxyAlias.aliasHost

@Suite("RemoteLoopbackHTTPRequestRewriter")
struct RemoteLoopbackHTTPRequestRewriterTests {
    @Test("rewrites Host, Origin, and Referer alias headers back to the localhost family")
    func rewritesAliasHeaders() {
        let request = "GET /index.html HTTP/1.1\r\nHost: \(alias):3000\r\nOrigin: http://\(alias):3000\r\nReferer: http://\(alias):3000/app\r\nAccept: */*\r\n\r\nBODY"
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: Data(request.utf8),
            aliasHost: alias
        )
        let text = String(decoding: rewritten, as: UTF8.self)
        #expect(text.contains("Host: localhost:3000"))
        #expect(text.contains("Origin: http://localhost:3000"))
        #expect(text.contains("Referer: http://localhost:3000/app"))
        // Untouched header and body survive byte-for-byte.
        #expect(text.contains("Accept: */*"))
        #expect(text.hasSuffix("\r\n\r\nBODY"))
    }

    @Test("maps alias subdomains to .localhost subdomains")
    func rewritesAliasSubdomain() {
        let request = "GET / HTTP/1.1\r\nHost: app.\(alias)\r\n\r\n"
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: Data(request.utf8),
            aliasHost: alias
        )
        #expect(String(decoding: rewritten, as: UTF8.self).contains("Host: app.localhost"))
    }

    @Test("rewrites absolute-form request-line URLs")
    func rewritesRequestLineURL() {
        let request = "GET http://\(alias):8080/path HTTP/1.1\r\nHost: \(alias):8080\r\n\r\n"
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: Data(request.utf8),
            aliasHost: alias
        )
        #expect(String(decoding: rewritten, as: UTF8.self).hasPrefix("GET http://localhost:8080/path HTTP/1.1\r\n"))
    }

    @Test("returns non-HTTP and incomplete-header payloads unchanged")
    func leavesNonRewritableDataAlone() {
        let nonHTTP = Data([0x05, 0x01, 0x00])
        #expect(RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(data: nonHTTP, aliasHost: alias) == nonHTTP)

        let incomplete = Data("GET / HTTP/1.1\r\nHost: \(alias)\r\n".utf8)
        #expect(RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(data: incomplete, aliasHost: alias) == incomplete)
    }

    @Test("allowIncompleteHeadersAtEOF rewrites a header block with no terminator")
    func rewritesIncompleteHeadersAtEOF() {
        let incomplete = Data("GET / HTTP/1.1\r\nHost: \(alias)\r\n".utf8)
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: incomplete,
            aliasHost: alias,
            allowIncompleteHeadersAtEOF: true
        )
        #expect(String(decoding: rewritten, as: UTF8.self).contains("Host: localhost"))
    }

    @Test("hosts outside the alias domain are untouched")
    func leavesForeignHostsAlone() {
        let request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let data = Data(request.utf8)
        #expect(RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(data: data, aliasHost: alias) == data)
    }
}

@Suite("RemoteLoopbackHTTPResponseRewriter")
struct RemoteLoopbackHTTPResponseRewriterTests {
    @Test("rewrites Location and Access-Control-Allow-Origin loopback hosts to the alias")
    func rewritesURLHeaders() {
        let response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:3000/next\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\n\r\n"
        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: Data(response.utf8),
            aliasHost: alias
        )
        let text = String(decoding: rewritten, as: UTF8.self)
        #expect(text.contains("Location: http://\(alias):3000/next"))
        // 127.0.0.1 is not in the localhost *name* family, so it stays.
        #expect(text.contains("Access-Control-Allow-Origin: http://127.0.0.1"))
    }

    @Test("rewrites Set-Cookie Domain attributes, preserving a leading dot")
    func rewritesCookieDomain() {
        let response = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Domain=.localhost; Path=/\r\n\r\n"
        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: Data(response.utf8),
            aliasHost: alias
        )
        #expect(String(decoding: rewritten, as: UTF8.self).contains("Domain=.\(alias)"))
    }

    @Test("non-HTTP payloads and headerless data pass through unchanged")
    func leavesNonResponsesAlone() {
        let raw = Data("not an http response".utf8)
        #expect(RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(data: raw, aliasHost: alias) == raw)
    }
}

@Suite("RemoteLoopbackHTTPRequestStreamRewriter")
struct RemoteLoopbackHTTPRequestStreamRewriterTests {
    @Test("buffers chunks until the header terminator, then rewrites once and passes the rest through")
    func buffersThenRewritesThenPassesThrough() {
        var rewriter = RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: alias)
        let part1 = Data("GET / HTTP/1.1\r\nHost: \(alias)".utf8)
        #expect(rewriter.rewriteNextChunk(part1, eof: false).isEmpty)

        let part2 = Data("\r\n\r\nBODY".utf8)
        let flushed = rewriter.rewriteNextChunk(part2, eof: false)
        let text = String(decoding: flushed, as: UTF8.self)
        #expect(text.contains("Host: localhost"))
        #expect(text.hasSuffix("\r\n\r\nBODY"))

        let later = Data("Host: \(alias) raw body bytes".utf8)
        #expect(rewriter.rewriteNextChunk(later, eof: false) == later)
    }

    @Test("EOF flushes buffered incomplete headers, rewritten")
    func eofFlushesIncompleteHeaders() {
        var rewriter = RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: alias)
        let partial = Data("GET / HTTP/1.1\r\nHost: \(alias)\r\n".utf8)
        let flushed = rewriter.rewriteNextChunk(partial, eof: true)
        #expect(String(decoding: flushed, as: UTF8.self).contains("Host: localhost"))
    }
}
